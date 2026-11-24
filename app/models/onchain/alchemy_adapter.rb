# frozen_string_literal: true

class Onchain::AlchemyAdapter < Onchain::EvmAdapter
  class AccessError < Onchain::Chains::UnreachableError; end

  def balance_backend
    @balance_backend ||= Provider::Alchemy.new(network: network)
  end

  alias_method :history_backend, :balance_backend

  def provider_error_classes
    [ Provider::Alchemy::RateLimitError, Provider::Alchemy::ApiError ]
  end

  private
    def chain_error_for(error)
      error.is_a?(Provider::Alchemy::AccessError) ? AccessError : super
    end

    def detection_backend
      @detection_backend ||= Provider::Alchemy.new(network: network, request_timeout: Onchain::DetectionBudget.timeout,
                                                    max_retries: Onchain::DetectionBudget.retries)
    end

    def network
      Onchain::Chains::ALCHEMY_NETWORKS.fetch(chain)
    end
end
