# frozen_string_literal: true

require 'async'
require_relative '../lib/cordis'

module AsyncHelpers
  # Every async spec that could hang gets wrapped in a timeout
  def with_reactor(timeout: 2, &)
    Sync do |task|
      task.with_timeout(timeout, &)
    end
  end

  # Let deferred load/unload transitions run (upstream tests' await sleep())
  def tick(count = 1)
    count.times { Async::Task.current.yield }
  end
end

RSpec.configure do |config|
  config.include AsyncHelpers
  config.order = :random
  Kernel.srand config.seed
end
