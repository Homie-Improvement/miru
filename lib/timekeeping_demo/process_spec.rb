# frozen_string_literal: true

module TimekeepingDemo
  # One process of the demo runtime: the application it belongs to, the
  # arguments it is started with, its absolute working directory and the whole
  # environment it receives.
  ProcessSpec = Data.define(:name, :app, :argv, :chdir, :env)
end
