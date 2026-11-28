require "test_helper"

class Entry::NonCashValueTest < ActiveSupport::TestCase
  test "reads previously synced trade quantities and prices without a provider connection" do
    entry = entries(:trade)
    entry.update!(source: "kraken", amount: 0)
    entry.trade.update!(qty: 2, price: 40, currency: "EUR", extra: { kraken: { type: "staking" } })

    reward = entry.reload.non_cash_value
    assert_equal :reward, reward.kind
    assert_equal Money.new(80, "EUR"), reward.value

    entry.update!(source: "onchain_wallet")
    entry.trade.update!(investment_activity_label: "Transfer", qty: -2, extra: {})
    transfer = entry.reload.non_cash_value
    assert_equal :transfer, transfer.kind
    assert_equal(-2, transfer.quantity)
    assert_equal reward.value, transfer.value

    entry.update!(source: "coinbase")
    assert_nil entry.reload.non_cash_value
  end

  test "reads the signed quantity of an unpriced wallet transaction and ignores malformed movements" do
    entry = entries(:transaction)
    entry.update!(source: "onchain_wallet", amount: 0)
    entry.transaction.update!(extra: { onchain_wallet: { amount: "-0.025" } })

    transfer = entry.reload.non_cash_value
    assert_equal(-0.025.to_d, transfer.quantity)
    assert_nil transfer.value

    [ nil, "0", "NaN", "Infinity", "unknown" ].each do |amount|
      entry.transaction.extra = { "onchain_wallet" => { "amount" => amount } }
      assert_nil entry.non_cash_value
    end
  end
end
