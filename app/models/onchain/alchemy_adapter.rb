# frozen_string_literal: true

class Onchain::AlchemyAdapter < Onchain::EvmAdapter
  class AccessError < Onchain::Chains::UnreachableError; end

  def fetch_snapshot(address)
    super
  ensure
    # The two balance reads share one Portfolio response within this snapshot.
    @balance_backend = nil
  end

  def balance_backend
    @balance_backend ||= Provider::Alchemy.new(network: network)
  end

  alias_method :history_backend, :balance_backend

  def provider_error_classes
    [ Provider::Alchemy::RateLimitError, Provider::Alchemy::ApiError ]
  end

  private
    def wrap_provider_errors
      super do
        yield
      rescue Provider::Alchemy::AccessError => e
        raise AccessError, e.message
      end
    end

    def detection_backend
      @detection_backend ||= Provider::Alchemy.new(network: network, request_timeout: Onchain::DetectionBudget.timeout,
                                                    max_retries: Onchain::DetectionBudget.retries)
    end

    def token_assets(address)
      assets = super
      @assets_truncated ||= balance_backend.assets_truncated
      assets
    end

    def network
      Onchain::Chains::ALCHEMY_NETWORKS.fetch(chain)
    end
end
