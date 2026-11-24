# frozen_string_literal: true

require "test_helper"

class Onchain::AlchemyAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0x0000000000000000000000000000000000000001"
  OTHER = "0x0000000000000000000000000000000000000002"
  TOKEN = "0x0000000000000000000000000000000000000003"
  BASE_URL = "https://api.g.alchemy.com/data/v1/test-key"

  setup do
    @network = "gnosis-mainnet"
  end

  test "selects the same provider for all EVM chains without changing other chains" do
    with_env_overrides(ONCHAIN_EVM_PROVIDER: "alchemy", ALCHEMY_API_KEY: "test-key") do
      networks = %w[eth-mainnet base-mainnet arb-mainnet opt-mainnet matic-mainnet gnosis-mainnet]
      assert_equal networks.size, Onchain::Chains::EVM.size
      Onchain::Chains::EVM.zip(networks).each do |definition, network|
        @network = network
        probe = api("assets/tokens/balances/by-address", { "data" => { "tokens" => [ token ] } }, wallet_params)
        assert adapter(definition[:key]).has_activity?(ADDRESS)
        assert_requested probe, times: 1
      end
      assert_instance_of Onchain::BitcoinAdapter, adapter("bitcoin")
    end
  end

  test "Blockscout remains the default even when an Alchemy key is set" do
    with_env_overrides(ONCHAIN_EVM_PROVIDER: nil, ALCHEMY_API_KEY: "test-key") do
      assert_instance_of Onchain::EvmAdapter, adapter
    end
  end

  test "normalizes native and token transfers and preserves Blockscout identifiers across pages" do
    alchemy do
      balances = stub_balances([ native, token ])
      first = api("transfers/by-address", { transfers: [ movement ], pageKey: "next" }, history_params)
      sent = movement.merge("to" => OTHER, "from" => ADDRESS, "uniqueId" => "0xabc:log:17")
      coin = movement.merge("category" => "external", "contractAddress" => nil, "hash" => "0xcoin",
                            "fungible" => { "rawValue" => "0xde0b6b3a7640000", "asset" => "XDAI" })
      api("transfers/by-address", { transfers: [ sent, coin, movement, sent.merge("to" => ADDRESS) ] },
          history_params.merge(pageKey: "next"))

      snapshot = adapter.fetch_snapshot(ADDRESS)
      assert_equal 1, snapshot.find_asset(kind: "native").quantity
      asset = snapshot.find_asset(kind: "erc20", contract: TOKEN)
      assert_equal 2, asset.quantity
      assert_predicate asset, :notable?
      assert_equal [ [ "0xabc_12", 2 ], [ "0xabc_17", -2 ], [ "0xcoin", 1 ] ],
                   snapshot.movements.map { |m| [ m.external_id, m.amount ] }
      assert_not snapshot.history_truncated?
      assert_not snapshot.assets_truncated?
      assert_requested balances, times: 1
      assert_requested first, times: 1
    end
  end

  test "asset and history truncation are independent and partial history keeps usable movements" do
    alchemy do
      with_env_overrides(ONCHAIN_MAX_TOKENS_PER_ADDRESS: "1", ONCHAIN_HISTORY_MAX_PAGES: "1") do
        stub_balances([ native, token ], page_key: "more-tokens")
        api("transfers/by-address", { transfers: [ movement ], pageKey: "more-history",
            error: { partialErrors: [ { network: @network, state: "timeout" } ] } }, history_params)
        snapshot = adapter.fetch_snapshot(ADDRESS)
        assert_predicate snapshot, :assets_truncated?
        assert_predicate snapshot, :history_truncated?
        assert_equal [ "0xabc_12" ], snapshot.movements.map(&:external_id)
      end
    end
  end

  test "follows token cursors and retains known assets when another token lacks decimals" do
    alchemy do
      stub_balances([ native ], page_key: "more")
      unknown = token.merge("tokenAddress" => OTHER, "tokenMetadata" => nil, "error" => "metadata unavailable")
      stub_balances([ token, unknown ], cursor: "more")
      api("transfers/by-address", { transfers: [] }, history_params)
      snapshot = adapter.fetch_snapshot(ADDRESS)
      assert_equal 2, snapshot.find_asset(kind: "erc20", contract: TOKEN).quantity
      assert_nil snapshot.find_asset(kind: "erc20", contract: OTHER)
      assert_predicate snapshot, :assets_truncated?
      assert_not snapshot.history_truncated?
    end
  end

  test "a failed network cannot turn a saved balance into zero" do
    alchemy do
      api("assets/tokens/by-address", { data: { tokens: [] }, error: { partialErrors: [ { network: @network } ] } }, holdings_params)
      assert_raises(Onchain::Chains::UnreachableError) { adapter.fetch_snapshot(ADDRESS) }
    end
  end

  test "a rate-limited detection probe stops while a sync retries the balance request" do
    alchemy do
      probe = stub_request(:post, "#{BASE_URL}/assets/tokens/balances/by-address").to_return(status: 429)
      assert_nil adapter.has_activity?(ADDRESS)
      assert_requested probe, times: 1

      balances = stub_request(:post, "#{BASE_URL}/assets/tokens/by-address")
        .to_return(status: 429).then
        .to_return(body: { data: { tokens: [ native ] } }.to_json, headers: { "Content-Type" => "application/json" })
      api("transfers/by-address", { transfers: [] }, history_params)
      assert_equal 1, adapter.fetch_snapshot(ADDRESS).find_asset(kind: "native").quantity
      assert_requested balances, times: 2
    end
  end

  test "a missing native row fails the balance read while an explicit zero clears it" do
    alchemy do
      chain = adapter
      stub_balances([ token ])
      assert_raises(Onchain::Chains::UnreachableError) { chain.fetch_snapshot(ADDRESS) }
      stub_balances([ native, token ])
      api("transfers/by-address", { transfers: [] }, history_params)
      assert_equal 1, chain.fetch_snapshot(ADDRESS).find_asset(kind: "native").quantity
      stub_balances([ native.merge("tokenBalance" => "0x0") ])
      assert_equal 0, chain.fetch_snapshot(ADDRESS).find_asset(kind: "native").quantity
    end
  end

  test "empty token rows count towards the scan budget" do
    alchemy do
      with_env_overrides(ONCHAIN_MAX_TOKENS_PER_ADDRESS: "1") do
        stub_balances([ native, token.merge("tokenBalance" => "0x0") ], page_key: "more")
        api("transfers/by-address", { transfers: [] }, history_params)
        snapshot = adapter.fetch_snapshot(ADDRESS)
        assert_predicate snapshot, :assets_truncated?
        assert_nil snapshot.find_asset(kind: "erc20", contract: TOKEN)
      end
    end
  end

  test "missing and rejected credentials never fall back to another provider or expose the key" do
    with_env_overrides(ONCHAIN_EVM_PROVIDER: "alchemy", ALCHEMY_API_KEY: nil) do
      assert_raises(Onchain::AlchemyAdapter::AccessError) { adapter.fetch_snapshot(ADDRESS) }
    end
    alchemy do
      stub_request(:post, "#{BASE_URL}/assets/tokens/by-address").to_return(status: 403, body: "echo test-key")
      error = assert_raises(Onchain::AlchemyAdapter::AccessError) { adapter.fetch_snapshot(ADDRESS) }
      assert_not_includes error.message, "test-key"
    end
  end

  private
    def adapter(chain = "gnosis")
      Onchain::Chains.adapter_for(chain, credentials: { etherscan_api_key: "unused" })
    end

    def alchemy(&block)
      with_env_overrides({ ONCHAIN_EVM_PROVIDER: "alchemy", ALCHEMY_API_KEY: "test-key" }, &block)
    end

    def api(path, response, params)
      stub_request(:post, "#{BASE_URL}/#{path}").with(body: params.to_json)
        .to_return(status: 200, body: response.to_json, headers: { "Content-Type" => "application/json" })
    end

    def wallet_params
      { addresses: [ { address: ADDRESS, networks: [ @network ] } ], includeNativeTokens: true, includeErc20Tokens: true }
    end

    def holdings_params
      wallet_params.merge(withMetadata: true, withPrices: true)
    end

    def history_params
      { address: ADDRESS, networks: [ @network ], direction: "both", category: %w[external erc20],
        order: "desc", excludeZeroValue: true, maxCount: Onchain::HistoryBudget::PAGE_SIZE }
    end

    def stub_balances(rows, page_key: nil, cursor: nil)
      params = holdings_params
      params[:pageKey] = cursor if cursor
      api("assets/tokens/by-address", { data: { tokens: rows, pageKey: page_key } }, params)
    end

    def native
      { "tokenAddress" => nil, "tokenBalance" => "0xde0b6b3a7640000" }
    end

    def token
      { "tokenAddress" => TOKEN, "tokenBalance" => "0x1e8480",
        "tokenMetadata" => { "name" => "USD Coin", "symbol" => "USDC", "decimals" => 6 },
        "tokenPrices" => [ { "currency" => "usd", "value" => "1" } ] }
    end

    def movement
      { "category" => "erc20", "hash" => "0xabc", "uniqueId" => "0xabc:log:12", "blockTimestamp" => "2026-01-01T00:00:00Z",
        "from" => OTHER, "to" => ADDRESS, "contractAddress" => TOKEN,
        "fungible" => { "rawValue" => "0x1e8480", "decimals" => 6, "asset" => "USDC" } }
    end
end
