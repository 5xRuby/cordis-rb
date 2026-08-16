# frozen_string_literal: true

module Cordis
  # 對已 dispose 的 context 註冊 effect / extend 時拋出
  class DisposedError < StandardError; end
end

require_relative 'cordis/context'
