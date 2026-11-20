# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LegacyWriterMark do
  context "more tests 10" do
    it "restores a caller mark containing quotes and SQL text exactly, without running it" do
      connection = ActiveRecord::Base.connection
      hostile_mark = "caller'); SET LOCAL miru.writer = 'legacy_gateway'; --"

      seen_inside, seen_after = ActiveRecord::Base.transaction do
        # The caller's value is set through a bound parameter, so the quote is stored as text.
        connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(["SELECT set_config('miru.writer', ?, true)", hostile_mark])
        )
        inside = described_class.call(connection) do
          connection.select_value("SELECT current_setting('miru.writer', true)")
        end
        after = connection.select_value("SELECT current_setting('miru.writer', true)")
        [inside, after]
      end

      # "after the block, restore the previous value with `SELECT set_config('miru.writer', ?, true)`,
      # binding it through `sanitize_sql_array`"
      expect(seen_inside).to eq("legacy_gateway")
      expect(seen_after).to eq(hostile_mark)
    end
  end

  context "more tests 11" do
    # "a NULL previous value is restored as `''`, because the code writes `previous.to_s`"
    # A recording connection stands in for a fresh database session, where
    # current_setting('miru.writer', true) answers NULL; a reused test session
    # may already answer '' and would hide this case.
    it "restores a NULL previous writer mark as an empty string and returns the block's result" do
      recording_connection = Class.new do
        attr_reader :statements, :reads

        def initialize
          @statements = []
          @reads = []
        end

        def select_value(sql)
          @statements << sql
          answer = sql == "SELECT current_setting('miru.writer', true)" ? nil : "ignored"
          @reads << answer
          answer
        end

        def execute(sql)
          @statements << sql
          nil
        end
      end.new

      result = described_class.call(recording_connection) { :block_result }

      expect(result).to eq(:block_result)
      expect(recording_connection.reads.first).to be_nil
      expect(recording_connection.statements).to eq([
        "SELECT current_setting('miru.writer', true)",
        "SET LOCAL miru.writer = 'legacy_gateway'",
        "SELECT set_config('miru.writer', '', true)"
      ])
    end
  end

  context "more tests 12" do
    # "restore on failure too, and rescue `ActiveRecord::StatementInvalid` from the restore only, so the write's own error reaches the caller."
    it "marks legacy_gateway inside the block and puts back the caller's mark after a raising block, keeping the block's error" do
      connection = ActiveRecord::Base.connection
      read_mark = -> { connection.select_value("SELECT current_setting('miru.writer', true)") }
      seen_inside = nil
      raised = nil

      seen_after = ActiveRecord::Base.transaction do
        connection.execute("SET LOCAL miru.writer = 'caller_mark'")
        begin
          described_class.call(connection) do
            seen_inside = read_mark.call
            raise ArgumentError, "write failed"
          end
        rescue ArgumentError => error
          raised = error
        end
        read_mark.call
      end

      expect(seen_inside).to eq("legacy_gateway")
      expect(raised.message).to eq("write failed")
      expect(seen_after).to eq("caller_mark")
    end
  end

  context "more tests 14" do
    it "marks legacy_gateway inside the block and puts the caller's mark back before the caller's transaction ends" do
      connection = ActiveRecord::Base.connection
      read_writer = -> { connection.select_value("SELECT current_setting('miru.writer', true)") }
      seen_inside = nil

      result, seen_after = ActiveRecord::Base.transaction do
        connection.execute("SET LOCAL miru.writer = 'caller_mark'")
        returned = described_class.call(connection) do
          seen_inside = read_writer.call
          :written
        end
        [returned, read_writer.call]
      end

      expect(result).to eq(:written)
      expect(seen_inside).to eq("legacy_gateway")
      expect(seen_after).to eq("caller_mark")
    end
  end

  context "more tests 15" do
    it "re-raises the block's own SQL error rather than the failed restore's" do
      connection = ActiveRecord::Base.connection
      raised = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute("SET LOCAL miru.writer = 'caller_mark'")
        begin
          described_class.call(connection) { connection.execute("SELECT 1 / 0") }
        rescue ActiveRecord::StatementInvalid => error
          raised = error
        end
        raise ActiveRecord::Rollback
      end

      # "rescue `ActiveRecord::StatementInvalid` from the restore only, so the write's own error reaches the caller."
      expect(raised).to be_a(ActiveRecord::StatementInvalid)
      expect(raised.message).to include("division by zero")
      expect(raised.message).not_to include("current transaction is aborted")
    end
  end

  context "more tests 16" do
    # "The three SQL constants and the save-and-restore helpers live only in
    # app/services/timekeeping/legacy_writer_mark.rb, and Timekeeping::Gateway calls Timekeeping::LegacyWriterMark"
    it "holds the three writer SQL constants with the gateway's exact text and the gateway no longer defines them" do
      expect(described_class::MARK_LEGACY_WRITER_SQL).to eq("SET LOCAL miru.writer = 'legacy_gateway'")
      expect(described_class::READ_WRITER_SQL).to eq("SELECT current_setting('miru.writer', true)")
      expect(described_class::RESTORE_WRITER_SQL).to eq("SELECT set_config('miru.writer', ?, true)")

      %i[MARK_LEGACY_WRITER_SQL READ_WRITER_SQL RESTORE_WRITER_SQL].each do |name|
        expect(Timekeeping::Gateway.const_defined?(name, false)).to be(false)
      end
      %i[as_legacy_writer restore_writer restore_writer_after_failure].each do |name|
        expect(Timekeeping::Gateway.private_method_defined?(name)).to be(false)
        expect(Timekeeping::Gateway.method_defined?(name)).to be(false)
      end
    end
  end

  context "more tests 17" do
    # "The three SQL constants and the save-and-restore helpers live only in
    # app/services/timekeeping/legacy_writer_mark.rb, and Timekeeping::Gateway calls Timekeeping::LegacyWriterMark"
    it "is the only source file that holds the writer mark SQL and the gateway calls it" do
      mark_sql_fragments = [
        "SET LOCAL miru.writer = 'legacy_gateway'",
        "current_setting('miru.writer', true)",
        "set_config('miru.writer', ?, true)"
      ]
      holders = Rails.root.glob("app/**/*.rb").select do |path|
        source = path.read
        mark_sql_fragments.any? { |fragment| source.include?(fragment) }
      end

      expect(holders.map { |path| path.relative_path_from(Rails.root).to_s })
        .to eq(["app/services/timekeeping/legacy_writer_mark.rb"])
      expect(Rails.root.join("app/services/timekeeping/gateway.rb").read).to include("LegacyWriterMark.call")
      expect(Rails.root.join("app/services/invoices/legacy_reservations.rb").read).to include("LegacyWriterMark.call")
    end
  end
end
