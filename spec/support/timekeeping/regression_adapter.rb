# frozen_string_literal: true

require "socket"

# spec/rails_helper.rb requires support files in sorted order, and this file
# sorts before timekeeping_database_reset.rb. Requiring the files it builds on
# here registers the owner-state hook first, so the per-example hook below
# runs after the owner state is set.
require_relative "owner_state"
require_relative "live_instance"
require_relative "timekeeping_database_reset"

# Points Timekeeping::EntryApiClient at a real Timekeeping app for a
# regression run in the timekeeping owner state, so the characterization specs
# of docs/architecture/timekeeping-soa.md section 12.1 run against the
# application that owns the data instead of FakeTimekeeping.
#
# It starts once per suite, only for a regression child with the live flag in
# the timekeeping state, and refuses a database whose name does not mark it as
# a test database before any process starts. No error raised here carries the
# database URL, the service token or the private key: the live instance's own
# errors hold its children's output, which can print the URL, and errors end
# up in CI logs.
module TimekeepingRegressionAdapter
  class BootError < StandardError; end

  OWNER_STATE = "timekeeping"
  ENABLED_FLAG = "1"
  FLAG_KEYS = %w[TIMEKEEPING_REGRESSION TIMEKEEPING_LIVE].freeze
  DATABASE_URL_KEY = TimekeepingDatabaseReset::DATABASE_URL_KEY
  BASE_URL_ENV = Timekeeping::EntryApiClient::BASE_URL_ENV
  PRIVATE_KEY_ENV = Timekeeping::UserToken::PRIVATE_KEY_ENV
  CLIENT_ENV_KEYS = [BASE_URL_ENV, PRIVATE_KEY_ENV].freeze
  # Every WebMock setting disable_net_connect! writes, so a failed start can
  # put the earlier connection policy back exactly.
  WEBMOCK_SETTINGS = %i[allow_net_connect allow_localhost allow net_http_connect_on_start].freeze
  PASSWORD_BREACH_LOOKUP = %r{\Ahttps://api\.pwnedpasswords\.com/range/}

  class << self
    # The running TimekeepingLiveInstance, or nil when the adapter is not running.
    attr_reader :current

    # Answers nil, touching nothing, unless env selects a live regression run
    # and owner_state is the timekeeping state. Otherwise answers the started
    # instance, or raises before any process starts when the database URL is
    # missing or does not name a test database.
    def start!(env: ENV, owner_state: TimekeepingOwnerState::SELECTED)
      return nil unless enabled?(env:, owner_state:)

      url = env.fetch(DATABASE_URL_KEY) do
        raise BootError, "#{DATABASE_URL_KEY} must name the live Timekeeping test database"
      end
      TestDatabaseGuard.require_test_database_url!(url)
      launch(url, TimekeepingOwnerState.fetch(owner_state).fetch(:admission_generation))
    end

    def enabled?(env:, owner_state:)
      FLAG_KEYS.all? { |key| env[key] == ENABLED_FLAG } && owner_state == OWNER_STATE
    end

    # spec/rails_helper.rb's around hook disables net connect after every
    # example, so the live app's address is allowed again before each one, and
    # the live database is emptied so no rows carry over from the example
    # before. The restriction also replaces the open network that the around
    # hook gives system and feature specs, so no example of a live run can
    # reach any other address.
    #
    # While VCR is on, its WebMock hook reports every connection as allowed,
    # so WebMock's allow list would block nothing. VCR is therefore turned off
    # for each example that uses no cassette; the around hook turns it back on.
    def prepare_example!(example)
      return unless current

      WebMock.disable_net_connect!(allow: [@allowed_address])
      VCR.turn_off! unless example.metadata[:vcr] || VCR.current_cassette
      stub_password_breach_lookup
      TimekeepingDatabaseReset.reset!(OWNER_STATE, env: { DATABASE_URL_KEY => @database_url })
    end

    # Stops the running instance, if any, and forgets it.
    def stop!
      instance = @current
      @current = nil
      @database_url = nil
      @allowed_address = nil
      instance&.stop
      nil
    end

    private

      # devise-pwned_password looks every new password up on the internet when
      # a user is saved. With VCR off that lookup is no longer let through, so
      # every example that creates a user would fail. In the test environment
      # config/initializers/devise.rb sets min_password_matches so high that
      # the answer never matters, so an empty answer stands in for it.
      def stub_password_breach_lookup
        WebMock.stub_request(:get, PASSWORD_BREACH_LOOKUP).to_return(status: 200, body: "")
      end

      def launch(url, admission_generation)
        saved_env = CLIENT_ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
        saved_webmock = WEBMOCK_SETTINGS.index_with { |name| WebMock::Config.instance.public_send(name) }
        port = free_port
        address = "#{TimekeepingLiveInstance::HOST}:#{port}"
        instance = nil
        begin
          WebMock.disable_net_connect!(allow: [address])
          reference_stub = TimekeepingLiveInstance::ReferenceStub.new
          instance = TimekeepingLiveInstance.start(reference_stub:, admission_generation:, port:, database_url: url)
          reference_stub.service_token = instance.service_token
          ENV[BASE_URL_ENV] = instance.base_url
          ENV[PRIVATE_KEY_ENV] = instance.private_key.to_pem
        rescue StandardError
          saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          saved_webmock.each { |name, value| WebMock::Config.instance.public_send(:"#{name}=", value) }
          stop_after_failed_start(instance)
          raise BootError, "the live Timekeeping instance did not start; its output is withheld because it can hold " \
                           "the database URL", cause: nil
        end
        @database_url = url
        @allowed_address = address
        @current = instance
      end

      # A failed start already raises a BootError of its own. An error from stopping
      # the instance would replace it and keep the start error, which can hold the
      # database URL, as its cause, so that error is dropped.
      def stop_after_failed_start(instance)
        instance&.stop
      rescue StandardError
        nil
      end

      def free_port
        server = TCPServer.new(TimekeepingLiveInstance::HOST, 0)
        server.addr[1]
      ensure
        server&.close
      end
  end
end

RSpec.configure do |config|
  config.before(:suite) { TimekeepingRegressionAdapter.start! }
  config.before { |example| TimekeepingRegressionAdapter.prepare_example!(example) }
  config.after(:suite) { TimekeepingRegressionAdapter.stop! }
end
