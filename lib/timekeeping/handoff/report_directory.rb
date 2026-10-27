# frozen_string_literal: true

require "digest"
require "fileutils"

module Timekeeping
  module Handoff
    # The files one handoff generation keeps for itself, under
    # <root>/generation-<n>: the step 2 money snapshots, the checkpoint's
    # capture time and digests, the invoice operation intents frozen at the
    # checkpoint, and the reconciliation report. A resumed run reads the
    # first three back instead of taking them again, so a money change, a
    # different capture time or an intent deleted or edited during an
    # interruption cannot slip into the comparison. Each generation has its
    # own directory, so a retry after an abort never reads the aborted
    # generation's files as its own.
    #
    # Every file is written to a temporary name and then renamed, so a reader
    # sees either the whole earlier file or the whole new one.
    class ReportDirectory
      # Raised when a file a resumed run needs is missing or cannot be read.
      # The run must stop rather than take a new snapshot or capture time.
      class Unreadable < StandardError; end

      MONEY_BEFORE_FILE = "money_before.json"
      CHECKPOINT_FILE = "checkpoint.json"
      SOURCE_INTENTS_FILE = "source_intents.json"
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

      # source_intents_digest is what write_source_intents returned, so the
      # checkpoint names the one intents file that belongs to it.
      def write_checkpoint(captured_at:, source_digest:, loaded_digest:, highest_entry_id:, source_intents_digest:)
        document = {
          "captured_at" => captured_at.utc.iso8601(6),
          "source_digest" => String(source_digest),
          "loaded_digest" => String(loaded_digest),
          "highest_entry_id" => Integer(highest_entry_id),
          "source_intents_digest" => String(source_intents_digest)
        }
        write(CHECKPOINT_FILE, JSON.generate(document))
      end

      # Returns { captured_at:, source_digest:, loaded_digest:, highest_entry_id:, source_intents_digest: },
      # with captured_at as the UTC Time that was written, to the microsecond.
      # A checkpoint without an intents digest has no frozen intents to
      # compare against, so it is unreadable rather than a match.
      def read_checkpoint
        document = JSON.parse(read(CHECKPOINT_FILE))
        {
          captured_at: Time.iso8601(document.fetch("captured_at")).utc,
          source_digest: string!(document.fetch("source_digest")),
          loaded_digest: string!(document.fetch("loaded_digest")),
          highest_entry_id: integer!(document.fetch("highest_entry_id")),
          source_intents_digest: string!(document.fetch("source_intents_digest"))
        }
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
        raise Unreadable, "#{path.join(CHECKPOINT_FILE)} is unreadable: #{error.class}"
      end

      # Writes the intents frozen at the checkpoint and returns the SHA-256 of
      # the file's text, which the checkpoint stores.
      def write_source_intents(rows)
        text = SourceIntentsFile.dump(rows)
        write(SOURCE_INTENTS_FILE, text)
        Digest::SHA256.hexdigest(text)
      end

      # The file must hash to the digest the checkpoint stored, so a file
      # edited or replaced after the checkpoint cannot become the baseline.
      def read_source_intents(digest:)
        text = read(SOURCE_INTENTS_FILE)
        unless Digest::SHA256.hexdigest(text) == digest
          raise Unreadable, "#{path.join(SOURCE_INTENTS_FILE)} does not match the checkpoint's intents digest"
        end

        SourceIntentsFile.load(text)
      rescue SourceIntentsFile::Unreadable => error
        raise Unreadable, "#{path.join(SOURCE_INTENTS_FILE)}: #{error.message}"
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
