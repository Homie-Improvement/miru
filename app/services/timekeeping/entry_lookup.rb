# frozen_string_literal: true

module Timekeeping
  # Finds the entry an update or destroy targets, in the store that owns it
  # (docs/architecture/timekeeping-soa.md section 3.3), so policies authorize
  # the owner's copy and an entry Timekeeping just created can be changed at
  # once, even while snapshot delivery is paused.
  #
  # The caller passes the ownership row it read under its own lock, so the
  # lookup and the write that follows it use the same owner. This module never
  # reads ownership itself.
  #
  # Every branch answers only an entry of the context's company. Any other
  # entry, whatever store returned it, raises ActiveRecord::RecordNotFound,
  # exactly as a missing id does, so an id never shows whether it exists in
  # another company.
  module EntryLookup
    # The entry, and the version Timekeeping holds for it. The version is sent
    # as If-Match on the write, so a change made after the policy check is
    # refused rather than applied. Only Timekeeping's answer carries one.
    Found = Data.define(:entry, :version)

    # Which of the company's entries a caller may target. A scope only ever
    # narrows the company's entries; none widens them.
    SCOPES = {
      company: ->(_entry, _context) { true },
      actor: ->(entry, context) { entry.user_id == context.actor.id }
    }.freeze

    module_function

    def find(ownership:, context:, entry_id:, local_owner:, read_client:, scope: :company)
      in_scope = SCOPES.fetch(scope)
      found = find_in_owner(ownership:, context:, entry_id:, local_owner:, read_client:)
      # The write that follows targets found.entry.id, so an answer for any
      # other id must not stand in for the requested one.
      unless found.entry.id.to_s == entry_id.to_s && found.entry.company_id == context.company.id &&
             in_scope.call(found.entry, context)
        raise not_found
      end

      found
    end

    def find_in_owner(ownership:, context:, entry_id:, local_owner:, read_client:)
      case EntryOwner.for(ownership)
      when :legacy
        Found.new(entry: context.company.timesheet_entries.kept.find(entry_id), version: nil)
      when :prepared
        Found.new(entry: local_owner.find_entry(context:, entry_id:), version: nil)
      when :timekeeping
        timekeeping_entry(context:, entry_id:, read_client:)
      else
        # An owner this code does not know must never be read as one it does.
        raise Gateway::OwnershipMoving
      end
    end

    # Hydrated with the row's own user, so an owner or admin can target a
    # colleague's entry; hydration still drops a row of another company, or
    # one whose project or user is not this company's.
    def timekeeping_entry(context:, entry_id:, read_client:)
      row = read_client.show_entry(company_id: context.company.id, entry_id:, acting_user_id: context.actor.id,
                                   request_id: context.request_id)
      entry = EntryReader.hydrate([row], company: context.company, user_id: row["user_id"]).first
      raise not_found if entry.nil?

      # Without a version the write would go out with no If-Match, and
      # Timekeeping would apply it to whatever the entry has become since the
      # policy check. The contract always answers one, so its absence is an
      # unexpected answer.
      version = row["version"]
      unless version.is_a?(Integer) && !version.negative?
        raise EntryWriteClient::Error, "Timekeeping entry show answered no valid version"
      end

      Found.new(entry:, version:)
    end

    def not_found
      ActiveRecord::RecordNotFound.new("Couldn't find TimesheetEntry", "TimesheetEntry")
    end
  end
end
