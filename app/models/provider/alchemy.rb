# frozen_string_literal: true

# Alchemy's Portfolio API uses the same host and app key on every network.
class Provider::Alchemy
  include Provider::EvmExplorer
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class ApiError < StandardError; end
  class RateLimitError < ApiError; end
  class AccessError < ApiError; end

  base_uri "https://api.g.alchemy.com"
  default_options.merge!({ timeout: 30, follow_redirects: false }.merge(httparty_ssl_options))
  headers "Content-Type" => "application/json", "Accept" => "application/json"

  attr_reader :truncated, :assets_truncated

  def initialize(network:, max_pages: Onchain::HistoryBudget.pages, request_timeout: 30, max_retries: 3)
    @network = network
    @key = ENV["ALCHEMY_API_KEY"].to_s.strip
    raise AccessError, "Set ALCHEMY_API_KEY to read EVM wallets" if @key.empty?

    @max_pages = max_pages
    @timeout = request_timeout
    @max_retries = max_retries
  end

  def has_activity?(address)
    response = request("assets/tokens/balances/by-address", wallet_params(address))
    data = token_page(response)
    return true if data.fetch("tokens").any? { |row| amount(row["tokenBalance"]).positive? }
    return nil if data["pageKey"].present?

    false
  end

  def native_balance(address)
    holdings(address).fetch(:native)
  end

  def token_balances(address)
    holdings(address).fetch(:tokens)
  end

  def transfers(address)
    params = { address: address, networks: [ @network ], direction: "both", category: %w[external erc20],
               order: "desc", excludeZeroValue: true, maxCount: Onchain::HistoryBudget::PAGE_SIZE }
    @truncated = false
    cursor = nil
    movements = []
    @max_pages.times do
      response = request("transfers/by-address", params)
      rows = response["transfers"]
      raise ApiError, "Invalid Alchemy transfer history" unless rows.is_a?(Array)

      @truncated ||= response["error"].present?
      rows.each do |row|
        movement = transfer(row, address)
        movements << movement if movement
      end
      cursor = response["pageKey"].presence
      break unless cursor
      break if params[:pageKey] == cursor
      params[:pageKey] = cursor
    end
    @truncated ||= cursor.present?
    movements.uniq { |movement| movement[:external_id] }
  end

  private
    def wallet_params(address)
      { addresses: [ { address: address, networks: [ @network ] } ], includeNativeTokens: true, includeErc20Tokens: true }
    end

    def token_page(response)
      data = response["data"]
      unless response["error"].blank? && data.is_a?(Hash) && data["tokens"].is_a?(Array) && data["tokens"].all?(Hash)
        raise ApiError, "Incomplete Alchemy balance response"
      end
      data
    end

    def holdings(address)
      return @holdings if @address == address && @holdings

      params = wallet_params(address).merge(withMetadata: true, withPrices: true)
      native = nil
      tokens = {}
      inspected = 0
      @assets_truncated = false
      seen_cursors = Set.new
      loop do
        data = token_page(request("assets/tokens/by-address", params))
        rows = data.fetch("tokens")
        rows.each do |row|
          if row.fetch("tokenAddress").nil?
            native = amount(row["tokenBalance"])
          else
            inspected += 1
            token = token_balance(row)
            tokens[token[:contract]] = token if token
          end
        end
        cursor = data["pageKey"].presence
        break unless cursor
        if rows.empty? || inspected >= Onchain::AssetBudget.tokens || !seen_cursors.add?(cursor)
          @assets_truncated = true
          break
        end
        params[:pageKey] = cursor
      end
      raise ApiError, "Missing Alchemy native balance" if native.nil?

      @address = address
      @holdings = { native: native, tokens: tokens.values }
    rescue KeyError
      raise ApiError, "Invalid Alchemy balance response"
    end

    def token_balance(row)
      raw = amount(row["tokenBalance"])
      return if raw.zero?

      metadata = row["tokenMetadata"] || {}
      unless metadata["decimals"].is_a?(Integer) && metadata["decimals"].between?(0, 255)
        # A missing scale makes this holding unknown. Preserve any previously
        # imported balance rather than interpreting the raw units as whole tokens.
        @assets_truncated = true
        return
      end
      price = Array(row["tokenPrices"]).find { |quote| quote["currency"] == "usd" }
      { contract: row.fetch("tokenAddress").downcase, name: metadata["name"], symbol: metadata["symbol"],
        decimals: metadata["decimals"], raw_amount: raw, rate: price&.fetch("value", nil)&.to_d }
    end

    def transfer(row, address)
      incoming = address.casecmp?(row["to"].to_s)
      outgoing = address.casecmp?(row["from"].to_s)
      return if incoming == outgoing

      fungible = row.fetch("fungible")
      raw = amount(fungible.fetch("rawValue"))
      hash = row.fetch("hash")
      case row.fetch("category")
      when "external"
        id = hash
        decimals = 18
      when "erc20"
        # Blockscout and Etherscan already identify these trades by hash_logIndex.
        index = row["uniqueId"].to_s[/\A#{Regexp.escape(hash)}:log:(\d+)\z/, 1]
        raise ApiError, "Missing Alchemy transfer log index" unless index
        id = "#{hash}_#{index.to_i}"
        contract = row.fetch("contractAddress").downcase
        decimals = fungible["decimals"]
        unless decimals.is_a?(Integer) && decimals.between?(0, 255)
          @truncated = true
          return
        end
      else
        return
      end
      { external_id: id, contract: contract, symbol: fungible["asset"], decimals: decimals,
        raw_amount: incoming ? raw : -raw, timestamp: Time.iso8601(row.fetch("blockTimestamp")) }
    rescue KeyError, ArgumentError
      raise ApiError, "Invalid Alchemy transfer"
    end

    def amount(hex)
      raise ApiError, "Invalid Alchemy raw balance or transfer amount" unless hex.is_a?(String) && /\A0x[0-9a-f]+\z/i.match?(hex)

      Integer(hex, 16)
    end

    def request(endpoint, params)
      retries = 0
      begin
        response = translate_transport_errors do
          self.class.post("/data/v1/#{ERB::Util.url_encode(@key)}/#{endpoint}", body: params.to_json, timeout: @timeout)
        end
        raise AccessError, "Check the Alchemy key and enabled networks" if [ 401, 402, 403 ].include?(response.code)
        raise RateLimitError, "Alchemy rate limit exceeded" if response.code == 429
        raise ApiError, "Alchemy returned HTTP #{response.code}" unless response.success?

        body = translate_transport_errors { response.parsed_response }
        raise ApiError, "Invalid Alchemy response" unless body.is_a?(Hash)
        body
      rescue RateLimitError
        raise if retries >= @max_retries

        sleep(0.5 * 2**retries)
        retries += 1
        retry
      end
    end
end
