# frozen_string_literal: true

# Blockscout's multichain REST API routes each network through its EVM chain ID.
class Provider::Blockscout
  include Provider::EvmExplorer
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end
  class AccessDeniedError < Error; end
  class MissingApiKeyError < Error; end

  # Flags the v2 address summary returns alongside the coin balance. They are
  # what lets a token-only wallet (zero native balance) be detected without
  # touching transfer history.
  ACTIVITY_FLAGS = %w[has_tokens has_token_transfers has_logs].freeze

  ERC20_TYPE = "ERC-20"

  DEFAULT_MAX_PAGES = 10
  MIN_REQUEST_INTERVAL = 0.2
  MAX_RETRIES = 3

  base_uri "https://api.blockscout.com"
  default_options.merge!({ timeout: 30, follow_redirects: false }.merge(httparty_ssl_options))
  headers "Accept" => "application/json"

  # Parallel chain probes share the same key and request allowance.
  @request_mutex = Mutex.new
  def self.throttle_request
    @request_mutex.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      remaining = @last_request_at.to_f + MIN_REQUEST_INTERVAL - now
      sleep(remaining) if remaining.positive?
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # Whether the last transfer history read stopped on the page budget.
  attr_reader :truncated

  # Detection reads on the request thread and cannot afford the sync's patience,
  # so both the per-request timeout and the retry count are the caller's to set.
  def initialize(chain_id:, max_pages: DEFAULT_MAX_PAGES, request_timeout: nil, max_retries: MAX_RETRIES)
    @chain_id = Integer(chain_id)
    key = ENV["BLOCKSCOUT_API_KEY"].to_s.strip
    raise MissingApiKeyError, "Set BLOCKSCOUT_API_KEY to read EVM wallets" if key.empty?

    @max_pages = max_pages
    @request_options = { headers: { "Authorization" => "Bearer #{key}" }, timeout: request_timeout || 30 }
    @max_retries = max_retries
    @truncated = false
  end

  def has_activity?(address)
    summary = address_summary(address)

    summary["coin_balance"].to_s.to_d.positive? || ACTIVITY_FLAGS.any? { |flag| summary[flag] == true }
  end

  def native_balance(address)
    address_summary(address)["coin_balance"].to_s
  end

  def holdings(address)
    native = native_balance(address)
    tokens, truncated = token_holdings(address)
    Holdings.new(native, tokens, truncated)
  end

  def token_balances(address)
    token_holdings(address).first
  end

  def transfers(address)
    transactions, more_transactions = paginate("#{address_path(address)}/transactions")
    transfers, more_transfers = paginate("#{address_path(address)}/token-transfers?type=ERC-20")
    @truncated = more_transactions || more_transfers
    transactions.filter_map { |row| native_transfer(row, address) } +
      transfers.filter_map { |row| token_transfer(row, address) }
  end

  private
    def token_holdings(address)
      rows, truncated = paginate("#{address_path(address)}/token-balances")
      [ rows.filter_map { |row| token_balance(row) }, truncated ]
    end

    # The balances endpoint returns every token standard and rejects a type filter.
    def token_balance(entry)
      token_data = entry["token"].to_h
      return unless token_data["type"] == ERC20_TYPE

      contract = contract_of(token_data)
      return unless contract

      {
        contract: contract,
        symbol: token_data["symbol"],
        name: token_data["name"],
        decimals: token_data["decimals"].to_i,
        raw_amount: entry["value"].to_s,
        # Blockscout's own market signals, used only to decide which tokens are
        # worth surfacing first when an address holds thousands of them, and
        # which are worth pre-ticking.
        market_cap: token_data["circulating_market_cap"].to_s.presence&.to_d,
        rate: token_data["exchange_rate"].to_s.presence&.to_d
      }
    end

    def native_transfer(transaction, address)
      raw_amount = transaction["value"].to_s.to_i * transfer_direction(address, from: transaction.dig("from", "hash"), to: transaction.dig("to", "hash"))
      return if raw_amount.zero?

      {
        external_id: transaction["hash"],
        contract: nil,
        symbol: nil,
        decimals: 18,
        raw_amount: raw_amount,
        timestamp: parse_time(transaction["timestamp"])
      }
    end

    def token_transfer(transfer, address)
      token_data = transfer["token"].to_h
      total = transfer["total"].to_h
      contract = contract_of(token_data)
      return if contract.blank?

      raw_amount = total["value"].to_s.to_i * transfer_direction(address, from: transfer.dig("from", "hash"), to: transfer.dig("to", "hash"))
      return if raw_amount.zero?

      {
        external_id: transfer_external_id(transfer["transaction_hash"], contract, transfer["log_index"]),
        contract: contract,
        symbol: token_data["symbol"],
        decimals: (total["decimals"] || token_data["decimals"]).to_i,
        raw_amount: raw_amount,
        timestamp: parse_time(transfer["timestamp"])
      }
    end

    # Both contract fields occur in Blockscout responses.
    def contract_of(token)
      (token["address_hash"] || token["address"]).to_s.presence&.downcase
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def address_summary(address)
      data = api_get(address_path(address))
      raise ApiError, "Invalid Blockscout address summary" unless data.is_a?(Hash) && data.key?("coin_balance")

      data
    end

    def address_path(address)
      "/#{@chain_id}/api/v2/addresses/#{ERB::Util.url_encode(address.to_s)}"
    end

    def paginate(path)
      items = []
      next_params = nil

      @max_pages.times do
        url = path.dup
        url += (url.include?("?") ? "&" : "?") + URI.encode_www_form(next_params) if next_params.present?

        body = api_get(url)

        # Some v2 collections (token-balances) return a bare, complete array;
        # the paginated ones wrap items with cursor params.
        return [ items.concat(body), false ] if body.is_a?(Array)

        page = body["items"]
        raise ApiError, "Invalid Blockscout collection" unless page.is_a?(Array)
        items.concat(page)

        next_params = body["next_page_params"]
        break if next_params.blank? || page.empty?
      end

      # A cursor still in hand means there were more pages than the budget.
      [ items, next_params.present? ]
    end

    def api_get(path)
      request_with_rate_limit_retries(@max_retries, source: "#{self.class.name}(#{@chain_id})") do
        self.class.throttle_request
        handle_response(self.class.get(path, **@request_options))
      end
    end

    def handle_response(response)
      if [ 401, 402, 403 ].include?(response.code) || response.headers["cf-mitigated"] == "challenge"
        raise AccessDeniedError, "Blockscout rejected access to chain #{@chain_id}. Check BLOCKSCOUT_API_KEY."
      end
      raise RateLimitError, "Blockscout rate limit exceeded" if response.code == 429
      raise ApiError, "Blockscout API error: #{response.code}" unless response.code.between?(200, 299)

      data = response.parsed_response
      return data if data.is_a?(Hash) || data.is_a?(Array)

      raise ApiError, "Blockscout returned an invalid API response"
    end
end
