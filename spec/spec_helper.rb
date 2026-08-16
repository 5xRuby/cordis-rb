# frozen_string_literal: true

require_relative '../lib/cordis'

RSpec.configure do |config|
  config.order = :random
  Kernel.srand config.seed
end
