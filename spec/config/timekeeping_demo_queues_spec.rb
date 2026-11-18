# frozen_string_literal: true

require "rails_helper"
require "yaml"
require "erb"
require "open3"

RSpec.describe "Timekeeping demo queue entry point" do
  it "bin/timekeeping-demo-queue selects Solid Queue before it starts a supervisor from the given config, and each demo config runs only its dedicated queue" do
    source = Rails.root.join("bin/timekeeping-demo-queue").read
    adapter_at = source.index(/ActiveJob::Base\.queue_adapter\s*=\s*:solid_queue/)
    start_at = source.index(/SolidQueue::Supervisor\.start\(\s*load_configuration_from:/)
    expect(adapter_at).not_to be_nil
    expect(start_at).not_to be_nil
    # The test environment selects the :test adapter, so recurring runs would never reach the queue tables otherwise.
    expect(adapter_at).to be < start_at

    # "The default worker is not started, because the seeded data already holds queued integration jobs and the default worker would run them."
    {
      "config/solid_queue_timekeeping_demo_relay.yml" => "timekeeping_relay",
      "config/solid_queue_timekeeping_demo_invoice_operations.yml" => "invoice_operations"
    }.each do |path, queue|
      config = YAML.safe_load(ERB.new(Rails.root.join(path).read).result, aliases: true)
      %w[default development test].each do |section|
        queues = config.fetch(section).fetch("workers").map { |worker| worker["queues"] }
        expect([path, section, queues]).to eq([path, section, [queue]])
      end
    end
  end

  describe "dedicated demo configs" do
    def load_demo_config(path)
      YAML.safe_load(ERB.new(Rails.root.join(path).read).result, aliases: true)
    end

    let(:main_tasks) { load_demo_config("config/solid_queue.yml").dig("default", "dispatchers", 0, "recurring_tasks") }

    {
      "config/solid_queue_timekeeping_demo_relay.yml" => ["timekeeping_relay", "Timekeeping::RelayJob"],
      "config/solid_queue_timekeeping_demo_invoice_operations.yml" =>
        ["invoice_operations", "RecoverInvoiceOperationIntentsJob"]
    }.each do |path, (queue, job_class)|
      it "#{path} runs one single-thread #{queue} worker and schedules only #{job_class} as config/solid_queue.yml does" do
        config = load_demo_config(path)

        %w[default development test].each do |section|
          block = config.fetch(section)
          expect([section, block.fetch("workers").map { |worker| worker.slice("queues", "threads", "processes") }])
            .to eq([section, [{ "queues" => queue, "threads" => 1, "processes" => 1 }]])

          tasks = block.fetch("dispatchers").flat_map { |dispatcher| dispatcher.fetch("recurring_tasks").values }
          expect([section, tasks.map { |task| task["class"] }]).to eq([section, [job_class]])

          main_task = main_tasks.values.find { |task| task["class"] == job_class }
          expect([section, tasks.first.slice("class", "schedule")]).to eq([section, main_task.slice("class", "schedule")])
          expect(block.fetch("workers").pluck("queues")).not_to include("default", "billing_sync")
        end
      end
    end

    it "bin/timekeeping-demo-queue exits 64 without starting a supervisor when the config path is missing or absent" do
      script = Rails.root.join("bin/timekeeping-demo-queue").to_s
      [[], ["config/no_such_timekeeping_demo_queue.yml"]].each do |arguments|
        _output, status = Open3.capture2e(RbConfig.ruby, script, *arguments)
        expect([arguments, status.exitstatus]).to eq([arguments, 64])
      end
    end
  end
end
