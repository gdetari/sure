class Entry::NonCashValue < Data.define(:kind, :quantity, :unit_price)
  READERS = {
    "kraken" => KrakenAccount::LedgerProcessor,
    "onchain_wallet" => OnchainWalletAccount::Processor
  }.freeze

  def self.for(entry)
    READERS[entry.source]&.non_cash_value(entry.entryable) if entry.amount&.zero?
  end

  def self.build(kind, quantity, unit_price: nil)
    quantity = BigDecimal(quantity.to_s, exception: false)
    return unless quantity&.finite? && quantity.nonzero?
    return if kind == :reward && quantity.negative?

    price = unit_price&.amount
    unit_price = nil unless price&.finite? && price.positive?
    new(kind, quantity, unit_price)
  end

  def value
    unit_price * quantity.abs if unit_price
  end
end
