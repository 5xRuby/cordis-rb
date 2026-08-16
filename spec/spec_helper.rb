# frozen_string_literal: true

require 'async'
require_relative '../lib/cordis'

module AsyncHelpers
  # 所有可能吊死的 async spec 一律包 timeout
  def with_reactor(timeout: 2, &)
    Sync do |task|
      task.with_timeout(timeout, &)
    end
  end

  # 讓被延後的 load/unload transition 跑完(對應上游 test 的 await sleep())
  def tick(count = 1)
    count.times { Async::Task.current.yield }
  end
end

RSpec.configure do |config|
  config.include AsyncHelpers
  config.order = :random
  Kernel.srand config.seed
end
