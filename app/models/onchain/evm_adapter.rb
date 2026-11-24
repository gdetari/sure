# frozen_string_literal: true

# Every EVM network, read through an interchangeable explorer backend.
#
# One adapter class serves all of them: the network's identity (its label,
# native coin and explorer URL) is data in the chain registry, so adding a
# network is a registry entry rather than a branch here.
#
# The unit being tracked is the (chain, address) couple. A 0x address is valid on
# every EVM network and holds different balances on each, which is why detection
# asks each candidate network whether the address is worth tracking there — one
# bounded request per network, never history — and why the user chooses when more
# than one answers yes.
class Onchain::EvmAdapter
  include Onchain::ChainAdapter

  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/
  NATIVE_DECIMALS = 18

  # Below this, a priced holding is dust rather than something the holder is
  # tracking on purpose. Only used to decide what the review screen pre-ticks:
  # measured on a real airdropped address, market-cap presence alone leaves
  # thousands of tokens looking credible, while holding value separates them.
  DUST_VALUE = 1.to_d

  attr_reader :chain, :explorer_url, :etherscan_chain_id

  def initialize(chain:, explorer_url:, etherscan_chain_id: nil, credentials: {})
    @chain = chain.to_s
    @explorer_url = explorer_url
    @etherscan_chain_id = etherscan_chain_id
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Hex is hex: the mixed case of a checksummed address carries no identity, so
  # 0xABC… and 0xabc… are one wallet and must not become two.
  def canonical_address(address)
    address.to_s.strip.downcase
  end

  # Deliberately asks the keyless backend: its address summary reports token
  # holdings as well as the coin balance, so a wallet holding only ERC-20 tokens
  # is still found, and it costs exactly one request. An explorer being down
  # must not break the linking flow, so a failure means "not detected here"
  # rather than an error the user has to interpret.
  def has_activity?(address)
    return false unless valid_address?(address)

    detection_backend.has_activity?(address)
  rescue StandardError => e
    Rails.logger.warn("Onchain::EvmAdapter(#{chain}) - activity probe failed: #{e.class}")
    # Not false: an explorer that timed out has not told us the address is
    # empty here, and answering "no" would let detection settle on another
    # chain without ever asking the user.
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid EVM address" unless valid_address?(address)

    wrap_provider_errors do
      balances = balance_backend.holdings(address)
      held = balances.tokens.select { |token| scale(token[:raw_amount], token[:decimals]).positive? }
      surfaced = rank(held).first(Onchain::AssetBudget.tokens)
      native = definition.native_asset(quantity: scale(balances.native, NATIVE_DECIMALS))
      movements = best_effort_movements { movements(address) }

      Onchain::Snapshot.new(
        assets: [ native, *surfaced.map { |token| token_asset(token) } ],
        movements: movements || [],
        history_truncated: movements.nil? || history_backend.truncated,
        assets_truncated: balances.truncated || held.size > surfaced.size
      )
    end
  end

  # Either backend can be in play within one snapshot, so both error families
  # have to map onto the chain-agnostic ones.
  def provider_error_classes
    [
      [ Provider::Blockscout::RateLimitError, Provider::Etherscan::RateLimitError ],
      [ Provider::Blockscout::Error, Provider::Etherscan::Error ]
    ]
  end

  # What an address currently holds always comes from the keyless indexer, even
  # when a key is configured. Etherscan has no free endpoint that enumerates an
  # address's tokens, so a keyed read would have to sum transfer history — which
  # is wrong for a rebasing token and wrong outright once history is capped. The
  # summary that answers this is one request either way, so there is nothing to
  # buy here.
  def balance_backend
    keyless_backend
  end

  # History is where a key actually helps: it is the paginated, rate-limited
  # half of the work.
  def history_backend
    etherscan_backend || keyless_backend
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(chain)
    end

    def keyless_backend
      @keyless_backend ||= Provider::Blockscout.new(
        chain: chain,
        base_url: explorer_url,
        max_pages: Onchain::HistoryBudget.pages
      )
    end

    # Detection asks every candidate network in turn on the request thread, so it
    # reads with the detection budget rather than the sync's: one short attempt,
    # no retry.
    def detection_backend
      @detection_backend ||= Provider::Blockscout.new(
        chain: chain,
        base_url: explorer_url,
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end

    def etherscan_backend
      return nil if etherscan_chain_id.blank?
      return nil if credentials[:etherscan_api_key].blank?

      @etherscan_backend ||= Provider::Etherscan.new(
        api_key: credentials[:etherscan_api_key],
        chain_id: etherscan_chain_id,
        max_pages: Onchain::HistoryBudget.pages
      )
    end

    def token_asset(token)
      symbol = token[:symbol].presence || token[:contract].to_s.first(10)
      quantity = scale(token[:raw_amount], token[:decimals])
      definition.token_asset(
        symbol: symbol, name: token[:name].presence || symbol, decimals: token[:decimals],
        quantity: quantity, contract: token[:contract],
        notable: token[:rate].present? && quantity * token[:rate] >= DUST_VALUE
      )
    end

    # Market cap first, because that is the signal the indexer already gives us
    # for telling a real asset from an airdrop, then contract address so the
    # order — and therefore what survives the cap — is identical between two
    # reads of an unchanged address.
    def rank(tokens)
      tokens.sort_by do |token|
        [ token[:market_cap].present? ? 0 : 1, -token[:market_cap].to_d, token[:contract].to_s ]
      end
    end

    def movements(address)
      history_backend.transfers(address).filter_map do |transfer|
        next if transfer[:timestamp].blank?

        amount = scale(transfer[:raw_amount], transfer[:decimals])
        next if amount.zero?

        Onchain::Movement.new(
          external_id: transfer[:external_id],
          symbol: transfer[:symbol].presence || definition.native.symbol,
          contract: transfer[:contract],
          amount: amount,
          timestamp: transfer[:timestamp]
        )
      end
    end

    # Explorers report amounts in a token's smallest unit; decimals turn that
    # back into whole units.
    def scale(raw_amount, decimals)
      BigDecimal(raw_amount.to_s.presence || "0") / (10.to_d**decimals.to_i)
    rescue ArgumentError
      0.to_d
    end
end
