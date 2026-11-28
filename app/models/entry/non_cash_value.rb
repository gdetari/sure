class Entry::NonCashValue < Data.define(:kind, :quantity, :unit_price)
  def self.for(entry)
    return unless entry.amount&.zero? && entry.source.present?

    readers[entry.source]&.non_cash_value(entry.entryable)
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

  def self.readers
    @readers ||= Provider::Factory.registered_adapters.flat_map { |adapter| adapter.non_cash_value_sources.to_a }.to_h
  end
  private_class_method :readers
end
