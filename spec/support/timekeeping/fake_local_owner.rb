# frozen_string_literal: true

module Timekeeping
  # Stands in for the prepared monolith's local entry owner that
  # Timekeeping::Gateway takes as local_owner:. It records every call with its
  # arguments and writes nothing, so a spec can show the prepared branch went
  # only here. Lookups answer from the entries given at construction.
  class FakeLocalOwner
    attr_reader :calls

    def initialize(entries: {})
      @entries = entries
      @calls = []
    end

    def find_entry(context:, entry_id:)
      record(:find_entry, context:, entry_id:)
      @entries.fetch(entry_id.to_i) { raise ActiveRecord::RecordNotFound }
    end

    def create_entry(context:, user:, project:, attributes:)
      record(:create_entry, context:, user:, project:, attributes:)
      TimesheetEntry.new(attributes).tap do |entry|
        entry.user = user
        entry.project = project
      end
    end

    def update_entry(context:, entry:, project:, attributes:)
      record(:update_entry, context:, entry:, project:, attributes:)
      TimesheetEntry.new(entry.attributes.merge(attributes.to_h.stringify_keys)).tap do |updated|
        updated.user = entry.user
        updated.project = project
      end
    end

    def destroy_entry(context:, entry:)
      record(:destroy_entry, context:, entry:)
      true
    end

    private

      def record(method, **kwargs)
        @calls += [{ method:, kwargs: }]
      end
  end
end
