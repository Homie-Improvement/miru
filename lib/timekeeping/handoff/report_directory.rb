# frozen_string_literal: true

require "fileutils"

module Timekeeping
  module Handoff
    # The files one handoff generation keeps for itself, under
    # <root>/generation-<n>: the step 2 money snapshots, the checkpoint's
    # capture time and digests, and the reconciliation report. A resumed run
    # reads the first two back instead of taking them again, so a money change
    # or a different capture time during an interruption cannot slip into the
    # comparison. Each generation has its own directory, so a retry after an
    # abort never reads the aborted generation's files as its own.
    #
    # Every file is written to a temporary name and then renamed, so a reader
    # sees either the whole earlier file or the whole new one.
    class ReportDirectory
      # Raised when a file a resumed run needs is missing or cannot be read.
      # The run must stop rather than take a new snapshot or capture time.
      class Unreadable < StandardError; end

      MONEY_BEFORE_FILE = "money_before.json"
      CHECKPOINT_FILE = "checkpoint.json"
      RECONCILIATION_FILE = "reconciliation.json"

      attr_reader :path

      def initialize(root:, generation:)
        @path = Pathname(root).join("generation-#{Integer(generation)}")
      end

      def write_money_before(snapshots_by_company)
        write(MONEY_BEFORE_FILE, MoneySnapshotFile.dump(snapshots_by_company))
      end

      def read_money_before
        MoneySnapshotFile.load(read(MONEY_BEFORE_FILE))
      rescue MoneySnapshotFile::Unreadable => error
        raise Unreadable, "#{path.join(MONEY_BEFORE_FILE)}: #{error.message}"
      end

      # Whether settle has already stored the money baseline. A repeated settle
      # keeps that file, so a value changed in between is still caught.
      def money_before?
        path.join(MONEY_BEFORE_FILE).file?
      end

      # Whether the checkpoint step has already stored its capture time. With
      # no file the step has not started and may take a fresh capture time.
      def checkpoint?
        path.join(CHECKPOINT_FILE).file?
      end

      def write_checkpoint(captured_at:, source_digest:, loaded_digest:, highest_entry_id:)
        document = {
          "captured_at" => captured_at.utc.iso8601(6),
          "source_digest" => String(source_digest),
          "loaded_digest" => String(loaded_digest),
          "highest_entry_id" => Integer(highest_entry_id)
        }
        write(CHECKPOINT_FILE, JSON.generate(document))
      end

      # Returns { captured_at:, source_digest:, loaded_digest:, highest_entry_id: },
      # with captured_at as the UTC Time that was written, to the microsecond.
      def read_checkpoint
        document = JSON.parse(read(CHECKPOINT_FILE))
        {
          captured_at: Time.iso8601(document.fetch("captured_at")).utc,
          source_digest: string!(document.fetch("source_digest")),
          loaded_digest: string!(document.fetch("loaded_digest")),
          highest_entry_id: integer!(document.fetch("highest_entry_id"))
        }
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
        raise Unreadable, "#{path.join(CHECKPOINT_FILE)} is unreadable: #{error.class}"
      end

      def write_reconciliation(report)
        write(RECONCILIATION_FILE, JSON.pretty_generate(report))
      end

      private

        def write(name, text)
          FileUtils.mkdir_p(path)
          target = path.join(name)
          temporary = path.join("#{name}.tmp-#{Process.pid}")
          File.open(temporary, "w") do |file|
            file.write(text)
            file.flush
            file.fsync
          end
          File.rename(temporary, target)
        ensure
          FileUtils.rm_f(temporary) if temporary
        end

        def read(name)
          path.join(name).read
        rescue SystemCallError => error
          raise Unreadable, "#{path.join(name)} cannot be read: #{error.class}"
        end

        def string!(value)
          raise TypeError, "expected a string" unless value.is_a?(String)

          value
        end

        def integer!(value)
          raise TypeError, "expected an integer" unless value.is_a?(Integer)

          value
        end
    end
  end
end
