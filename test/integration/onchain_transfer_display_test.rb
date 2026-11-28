require "test_helper"

class OnchainTransferDisplayTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier, OnchainTestHelper

  setup do
    user = users(:family_admin)
    sign_in user
    asset = Onchain::Chains.find!("ethereum").native_asset(quantity: 1.to_d)
    item = create_onchain_wallet_item(family: user.family)
    @wallet = create_onchain_wallet_account(item: item, chain: "ethereum", asset: asset, address: "0x1111111111111111111111111111111111111111")
    @account = link_onchain_wallet_account!(@wallet)
    @processor = OnchainWalletAccount::Processor.new(@wallet)
    @date = 3.days.ago.to_date
    @security = Onchain::SecurityResolver.resolve(symbol: "ETH", name: "Ethereum")
    Security.any_instance.stubs(:import_provider_prices)
    @security.prices.create!(date: Date.current, price: 4_000, currency: "USD")
  end

  test "sent and received ETH show transfer-date values while cash stays zero" do
    @security.prices.create!(date: @date, price: 2_000, currency: "USD")
    import_movements("sent" => "-0.10182887", "received" => "0.00000005")

    get account_url(@account, tab: "activity")
    assert_response :success
    assert_value entry_for("sent"), "$203.66"
    assert_value entry_for("received"), "< $0.01"

    [
      [ "sent", "$203.66 USD", "0.10182887" ],
      [ "received", "< $0.01 USD", "0.00000005" ]
    ].each do |id, expected, quantity|
      entry = entry_for(id)
      get trade_url(entry)
      assert_response :success
      assert_select "h3 .privacy-sensitive", text: expected
      assert_detail "Quantity #{id}", quantity
      assert_detail "Unit price at transfer", "$2,000.00"
      assert_detail "Cash movement", "$0.00"
      assert_equal 0, entry.amount
    end
    assert_equal 0, @account.reload.cash_balance
  end

  test "a transfer without a dated quote is unavailable until it is priced" do
    import_movements("unpriced" => "0.25")
    entry = entry_for("unpriced")
    get account_url(@account, tab: "activity")
    assert_response :success
    assert_value entry, "Unavailable"
    get transaction_url(entry)
    assert_response :success
    assert_select "h3 .privacy-sensitive", text: "Unavailable"
    assert_detail "Quantity received", "0.25"
    assert_detail "Unit price at transfer", "Unavailable"
    assert_detail "Cash movement", "$0.00"

    @security.prices.create!(date: @date, price: 2_000, currency: "USD")
    assert_no_difference -> { @account.entries.count } do
      @processor.repair_display_only_movements
    end
    entry = entry_for("unpriced")
    get account_url(@account, tab: "activity")
    assert_response :success
    assert_value entry, "$500.00"
    assert_equal 0, entry.amount
  end

  private
    def import_movements(amounts)
      movements = amounts.map { |id, amount| { external_id: id, amount: amount, date: @date.to_s } }
      @wallet.update!(raw_movements_payload: { movements: movements })
      @processor.process
    end

    def entry_for(id)
      @account.entries.find_by!(external_id: "onchain_#{@wallet.id}_#{id}")
    end

    def assert_value(entry, expected)
      assert_select "##{dom_id(entry.entryable)}" do
        assert_select ".privacy-sensitive", text: expected
        assert_select "span", text: "Value at transfer"
      end
    end

    def assert_detail(label, expected)
      assert_select "dt", text: label do |labels|
        assert_equal expected, labels.first.next_element.text.strip
      end
    end
end
