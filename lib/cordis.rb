# frozen_string_literal: true

module Cordis
  class Error < StandardError; end

  # 在非 active 的 context 上建立 effect / plugin / listener
  class InactiveEffectError < Error; end

  # service 存取違規(without inject / inactive context / duplicate provide / set 違規)
  class ServiceError < Error; end

  # parallel 的彙總錯誤(Ruby 沒有內建 AggregateError)
  class AggregateError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super("#{errors.size} error(s): #{errors.map(&:message).join('; ')}")
    end
  end
end

require_relative 'cordis/fiber'
require_relative 'cordis/registry'
require_relative 'cordis/events'
require_relative 'cordis/context'
