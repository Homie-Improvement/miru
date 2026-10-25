# frozen_string_literal: true

require "timekeeping_rules"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
