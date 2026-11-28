# frozen_string_literal: true

# The data source interface used by Onchain::EvmAdapter.
#
# Amounts are returned in each token's smallest unit ("raw"), as strings or
# integers, because that is what every explorer reports and the only lossless
# form; the adapter scales them by the token's decimals.
module Provider::EvmExplorer
  Holdings = Data.define(:native, :tokens, :truncated)

  def holdings(address)
    Holdings.new(native_balance(address), token_balances(address), false)
  end

  # Whether this address is worth tracking on this chain.
  #
  # MUST cost at most one request and MUST NOT read paginated transfer history:
  # this is called once per candidate network every time someone pastes a 0x
  # address, so a history walk here would turn linking into dozens of requests.
  # @return [Boolean]
  def has_activity?(_address)
    raise NotImplementedError, "#{self.class} must implement #has_activity?"
  end

  # @return [String, Integer] native coin balance in wei
  def native_balance(_address)
    raise NotImplementedError, "#{self.class} must implement #native_balance"
  end

  # @return [Array<Hash>] { contract:, symbol:, name:, decimals:, raw_amount: }
  def token_balances(_address)
    raise NotImplementedError, "#{self.class} must implement #token_balances"
  end

  # Signed transfers, native and ERC-20 together. Positive raw_amount means the
  # address received; negative means it sent. `contract` is nil for the native
  # coin.
  # @return [Array<Hash>] { external_id:, contract:, symbol:, decimals:, raw_amount:, timestamp: }
  def transfers(_address)
    raise NotImplementedError, "#{self.class} must implement #transfers"
  end

  private
    # A self-transfer or a row unrelated to the wallet has no net movement.
    def transfer_direction(address, from:, to:)
      received = address.to_s.casecmp?(to.to_s)
      sent = address.to_s.casecmp?(from.to_s)
      return 0 if received == sent

      received ? 1 : -1
    end

    # A transaction can contain several transfers of the same token. Older
    # responses without a log index use the existing contract-based identifier.
    def transfer_external_id(transaction_hash, contract, log_index)
      [ transaction_hash, log_index.nil? ? contract : log_index ].join("_")
    end
end
