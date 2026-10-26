# frozen_string_literal: true

require "net/http"
require "open3"
require "puma"
require "rack"
require "socket"
require "tempfile"

# A real Timekeeping service, booted from timekeeping/ in its own process and
# bundle, for the specs that must see the service's own HTTP stack, database
# and write metrics rather than a fake. Its reference endpoint is a Rack app
# the spec serves from this process, so a spec can take it down for some
# writes.
#
# Needs TIMEKEEPING_DATABASE_URL pointing at a database the service may
# prepare and empty. Every failure to boot raises, so a spec that asked for a
# live instance fails instead of passing without one.
class TimekeepingLiveInstance
  class BootError < StandardError; end

  # The monolith's reference endpoint as the service reads it, answering from
  # the monolith's own records, or 503 while down is set.
  class ReferenceStub
    PATH = %r{\A/internal/v1/companies/(?<company_id>\d+)/reference\z}

    attr_accessor :down, :service_token

    def call(env)
      request = Rack::Request.new(env)
      return respond(503, reason: "unavailable") if down
      return respond(401, reason: "unauthorized") unless authorized?(request)

      path = PATH.match(request.path_info)
      return respond(404, reason: "not_found") unless path

      project_ids = request.params.fetch("project_ids", "").to_s.split(",")
      # Served on the stub server's own threads, which must hand their
      # database connection back after each request.
      facts = ActiveRecord::Base.connection_pool.with_connection do
        Timekeeping::ReferenceFacts.call(company: Company.find(Integer(path[:company_id], 10)), project_ids:)
      end
      respond(200, facts)
    end

    private

      def authorized?(request)
        service_token.present? && request.get_header("HTTP_AUTHORIZATION") == "Bearer #{service_token}"
      end

      def respond(status, body)
        [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
      end
  end

  SERVICE_DIRECTORY = Rails.root.join("timekeeping").to_s
  BOOT_TIMEOUT_SECONDS = 120
  HOST = "127.0.0.1"
  RAILS = %w[bundle exec rails].freeze
  # Runs once before the server starts: entry writes need the admission row at
  # generation 1.
  ADMIT_SCRIPT = <<~RUBY
    Timekeeping::Admission.ensure_initial!
    Timekeeping::Admission.admit!(generation: 1)
  RUBY
  # The service counts writes by company id, and the monolith specs restart
  # their id sequences, so counts left by an earlier example or run would be
  # added to a new company that reuses the id.
  CLEAR_METRICS_SCRIPT = <<~RUBY
    WriteMetricEvent.delete_all
    WriteMetricWindow.delete_all
  RUBY

  attr_reader :base_url, :service_token, :private_key

  def self.start(reference_stub:)
    new(reference_stub:).tap(&:start)
  end

  def initialize(reference_stub:)
    @reference_stub = reference_stub
    @service_token = "live-service-#{SecureRandom.hex(24)}"
    @private_key = OpenSSL::PKey::RSA.generate(2048)
  end

  def start
    start_reference_server
    port = free_port
    @base_url = "http://#{HOST}:#{port}"
    run_in_service!(*RAILS, "db:prepare")
    run_in_service!(*RAILS, "runner", ADMIT_SCRIPT)
    @log = Tempfile.new(["timekeeping-live", ".log"])
    # A pid file of its own, so a server left by an interrupted run never
    # stops this one from booting.
    pid_file = File.join(Dir.tmpdir, "timekeeping-live-#{port}.pid")
    @pid = spawn_in_service(*RAILS, "server", "-e", "test", "-b", HOST, "-p", port.to_s, "-P", pid_file)
    wait_until_ready
  rescue StandardError
    stop
    raise
  end

  # Stops the server and the reference endpoint; safe to call more than once.
  def stop
    if @pid
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
    @reference_server&.stop(true)
    @reference_server = nil
  end

  # Empties the service's write metrics; call it before each example.
  def clear_metrics!
    run_in_service!(*RAILS, "runner", CLEAR_METRICS_SCRIPT)
  end

  def reference_url
    "http://#{HOST}:#{@reference_port}"
  end

  # Sends one request with the service token and answers the Net::HTTPResponse.
  def service_post(path, body = nil)
    request(Net::HTTP::Post.new(URI.join(base_url, path)), body, "Bearer #{service_token}")
  end

  # Sends an entry write the way the monolith forwards one: a user token,
  # the admitted generation and a fresh idempotency key.
  def write_entry(company_id:, token:, body:)
    post = Net::HTTP::Post.new(URI.join(base_url, "/v1/companies/#{Integer(company_id)}/entries"))
    post["Ownership-Generation"] = "1"
    post["Idempotency-Key"] = SecureRandom.uuid
    request(post, body, "Bearer #{token}")
  end

  # The service's output, to explain a failed boot.
  def log_tail
    return "" unless @log

    File.read(@log.path).lines.last(40).join
  end

  private

    def service_env
      {
        "RAILS_ENV" => "test",
        "BUNDLE_GEMFILE" => File.join(SERVICE_DIRECTORY, "Gemfile"),
        "TIMEKEEPING_DATABASE_URL" => ENV.fetch("TIMEKEEPING_DATABASE_URL") do
          raise BootError, "TIMEKEEPING_DATABASE_URL must name the live Timekeeping test database"
        end,
        "TIMEKEEPING_TOKEN_PUBLIC_KEY" => private_key.public_key.to_pem,
        "TIMEKEEPING_SERVICE_TOKEN" => service_token,
        "MONOLITH_REFERENCE_URL" => reference_url,
        # The service's own process needs no monolith database setting.
        "DATABASE_URL" => nil
      }
    end

    # The monolith runs under its own bundle; boot.rb keeps an inherited
    # BUNDLE_GEMFILE, so without a clean environment the service would load
    # the monolith's gems and miss its own path gems.
    def run_in_service!(*command)
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e(service_env, *command, chdir: SERVICE_DIRECTORY)
      end
      raise BootError, "#{command.join(" ")} failed:\n#{output}" unless status.success?
    end

    def spawn_in_service(*command)
      Bundler.with_unbundled_env do
        Process.spawn(service_env, *command, chdir: SERVICE_DIRECTORY, out: @log.path, err: [:child, :out])
      end
    end

    def wait_until_ready
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT_SECONDS
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise BootError, "Timekeeping server exited during boot:\n#{log_tail}" if Process.wait(@pid, Process::WNOHANG)

        return if metrics_ready?

        sleep 0.25
      end
      raise BootError, "Timekeeping server was not ready within #{BOOT_TIMEOUT_SECONDS} s:\n#{log_tail}"
    end

    def metrics_ready?
      get = Net::HTTP::Get.new(URI.join(base_url, "/internal/v1/metrics"))
      request(get, nil, "Bearer #{service_token}").is_a?(Net::HTTPOK)
    rescue SystemCallError, IOError, Net::ProtocolError, Timeout::Error
      false
    end

    def request(request, body, authorization)
      request["Authorization"] = authorization
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      uri = request.uri
      Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
    end

    def start_reference_server
      @reference_server = Puma::Server.new(@reference_stub, nil, min_threads: 1, max_threads: 4)
      @reference_server.add_tcp_listener(HOST, 0)
      @reference_port = @reference_server.connected_ports.first
      @reference_server.run
    end

    def free_port
      server = TCPServer.new(HOST, 0)
      server.addr[1]
    ensure
      server&.close
    end
end
