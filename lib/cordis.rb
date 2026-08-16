# frozen_string_literal: true

module Cordis
  class Error < StandardError; end

  # Raised when creating an effect / plugin / listener on a non-active context
  class InactiveEffectError < Error; end

  # Service access violations (without inject / inactive context / duplicate provide / bad set)
  class ServiceError < Error; end

  # Aggregated errors from parallel (Ruby has no built-in AggregateError)
  class AggregateError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super("#{errors.size} error(s): #{errors.map(&:message).join('; ')}")
    end
  end
end

require_relative 'cordis/version'
require_relative 'cordis/fiber'
require_relative 'cordis/registry'
require_relative 'cordis/events'
require_relative 'cordis/context'
require_relative 'cordis/service'
