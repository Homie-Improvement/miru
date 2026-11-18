# frozen_string_literal: true

# Puma settings for the monolith web process of the local Timekeeping demo
# (Procfile.timekeeping). The bind address comes from the command line, which
# sets 127.0.0.1 only.
#
# This file deliberately leaves out config/puma.rb's Solid Queue plugin. That
# plugin starts the full config/solid_queue.yml supervisor, default worker
# included, whenever SOLID_QUEUE_IN_PUMA is set, and a developer's .env can set
# it after the demo launcher has filtered the environment.

max_threads = ENV.fetch("RAILS_MAX_THREADS", 3).to_i
threads max_threads, max_threads

environment ENV.fetch("RAILS_ENV", "development")

# A pid file of its own, so a regular development server never blocks this one.
pidfile "tmp/pids/timekeeping-demo-monolith.pid"
