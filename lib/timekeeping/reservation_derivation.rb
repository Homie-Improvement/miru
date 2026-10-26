# frozen_string_literal: true

require "digest"

module Timekeeping
  # The first-cutover reservations of docs/architecture/timekeeping-soa.md
  # section 10.3: the legacy monolith records an invoice's hold only as the
  # `locked` boolean, so the first checkpoint derives each reservation, and
  # the corrections section 10.4 lists, from `locked`, the invoice links and
  # the recorded seed disposition.
  #
  # Pure: it reads plain hashes and touches no database.
  module ReservationDerivation
    # The UUIDv5 namespace of every first-cutover reservation's operation_id.
    # Fixed, so a retried cutover derives the same operation ids.
    RESERVATION_NAMESPACE = "0b71cdcd-5fa4-4a15-9e2a-7e2d4f4b65f0"
    COMMITTED = "committed"
    CORRECTION_VERSION = 1

    # How each pre-flight list becomes a reservation owner. A list with no row
    # here gives no reservation. Orphans and conflicts never reach this table:
    # the recorded disposition can only hold unlocked links, so they refuse.
    OWNER_TABLE = {
      active: { owner: ->(facts) { facts[:kept].first }, disposition: "active" },
      retained: { owner: ->(facts) { facts[:discarded_non_drafts].first }, disposition: "retained" },
      # Only reached when the recorded disposition equals the live listing and
      # reserves every invoice; any other record refuses.
      unlocked_links: { owner: ->(facts) { facts[:kept].first }, disposition: "active" }
    }.freeze

    # Pre-flight lists that refuse the company whenever they hold an entry.
    REFUSED_LISTS = { orphans: "orphan", conflicts: "conflict" }.freeze

    module_function

    # company_id: the company the entries belong to by the project -> client ->
    # company join.
    # entries: [{ id:, locked:, company_id:, join_company_id:, row: }], where
    # company_id is the stored timesheet_entries.company_id and row the entry
    # as it goes into the checkpoint.
    # links: [{ entry_id:, invoice_id:, invoice_company_id:, draft:, discarded: }]
    # for every link that touches these entries or this company's invoices.
    # invoice_numbers: { invoice_id => number } for this company's invoices only.
    # recorded_invoices: this company's block of the recorded seed disposition,
    # { number => { "entry_ids" => [...], "disposition" => ... } }.
    #
    # Returns { reservations:, corrections:, refusals: }. Any refusal empties
    # reservations and corrections, so a refused company never yields a
    # partial derivation.
    def derive(company_id:, entries:, links:, invoice_numbers:, recorded_invoices:, generation:, captured_at:)
      classification = Preflight.classify(entries:, links:)
      refusals =
        tenant_refusals(company_id, entries, links) +
        list_refusals(classification) +
        disposition_refusals(classification, invoice_numbers, recorded_invoices.to_h)
      return { reservations: [], corrections: [], refusals: } if refusals.any?

      reservations = reservations_for(company_id, entries, links, classification, captured_at)
      { reservations:, corrections: corrections_for(company_id, entries, reservations, generation, captured_at), refusals: [] }
    end

    def operation_id(company_id:, entry_id:, invoice_id:)
      Digest::UUID.uuid_v5(RESERVATION_NAMESPACE, "#{company_id}/#{entry_id}/#{invoice_id}")
    end

    def tenant_refusals(company_id, entries, links)
      entry_ids = entries.pluck(:id)
      mismatched = entries.filter_map do |entry|
        next if entry[:company_id] == entry[:join_company_id] && entry[:join_company_id] == company_id

        "entry #{entry[:id]}: stored company_id #{entry[:company_id].inspect} differs from " \
          "its project's company #{entry[:join_company_id].inspect}"
      end
      foreign_invoices = links.filter_map do |link|
        next if link[:invoice_company_id] == company_id

        "entry #{link[:entry_id]}: linked to invoice #{link[:invoice_id]} of company #{link[:invoice_company_id].inspect}"
      end
      foreign_entries = links.filter_map do |link|
        next if entry_ids.include?(link[:entry_id])

        "invoice #{link[:invoice_id]}: links entry #{link[:entry_id]}, which is not an entry of this company"
      end
      (mismatched + foreign_invoices + foreign_entries).uniq
    end

    def list_refusals(classification)
      REFUSED_LISTS.flat_map do |list, label|
        classification.fetch(list).sort.map { |entry_id| "entry #{entry_id}: #{label} with no recorded disposition" }
      end
    end

    # The recorded listing must equal the live unlocked links invoice by
    # invoice, with every invoice reserved. Numbers are looked up only in this
    # company's invoices, so another company's number never resolves.
    def disposition_refusals(classification, invoice_numbers, recorded_invoices)
      unlocked_links = classification.fetch(:unlocked_links)
      unnumbered = unlocked_links.reject { |link| invoice_numbers[link[:invoice_id]] }
      live_invoices = (unlocked_links - unnumbered).group_by { |link| invoice_numbers.fetch(link[:invoice_id]) }
        .transform_values { |links| { "entry_ids" => links.pluck(:entry_id).sort, "disposition" => SeedDisposition::RESERVE } }
      unknown_numbers = recorded_invoices.keys - invoice_numbers.values

      label = "this company"
      recorded = { "companies" => { label => recorded_invoices } }
      live = { "companies" => { label => live_invoices } }

      unnumbered.map { |link| "entry #{link[:entry_id]}: invoice #{link[:invoice_id]} has no invoice number" } +
        unknown_numbers.map { |number| "recorded invoice #{number.inspect} is not an invoice of this company" } +
        SeedDisposition.invoice_differences(recorded, live) +
        SeedDisposition.unreserved_invoices(recorded)
    end

    def reservations_for(company_id, entries, links, classification, captured_at)
      links_by_entry = links.group_by { |link| link[:entry_id] }
      listed = OWNER_TABLE.keys.flat_map do |list|
        classification.fetch(list).map { |item| [item.is_a?(Hash) ? item[:entry_id] : item, list] }
      end.to_h

      entries.sort_by { |entry| entry[:id] }.filter_map do |entry|
        rule = OWNER_TABLE[listed[entry[:id]]]
        next unless rule

        facts = Preflight.entry_facts(entry, links_by_entry.fetch(entry[:id], []))
        invoice_id = rule[:owner].call(facts)
        {
          "company_id" => company_id,
          "entry_id" => entry[:id],
          "invoice_id" => invoice_id,
          "state" => COMMITTED,
          "disposition" => rule[:disposition],
          "operation_id" => operation_id(company_id:, entry_id: entry[:id], invoice_id:),
          "created_at" => captured_at
        }
      end
    end

    # A corrected entry is one whose reservation state differs from its legacy
    # `locked` value. Its snapshot is the copied row with only `locked` and
    # `version` changed; Timekeeping writes it to its outbox after the load.
    def corrections_for(company_id, entries, reservations, generation, captured_at)
      reserved_ids = reservations.pluck("entry_id")

      entries.sort_by { |entry| entry[:id] }.filter_map do |entry|
        reserved = reserved_ids.include?(entry[:id])
        next if reserved == (entry[:locked] == true)

        {
          "company_id" => company_id,
          "entry_id" => entry[:id],
          "generation" => generation,
          "captured_at" => captured_at,
          "snapshot" => entry[:row].merge("locked" => reserved, "version" => CORRECTION_VERSION)
        }
      end
    end
  end
end
