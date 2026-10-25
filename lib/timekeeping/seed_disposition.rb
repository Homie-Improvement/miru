# frozen_string_literal: true

module Timekeeping
  # The recorded seed disposition of docs/architecture/timekeeping-soa.md
  # section 10.4: for each seeded company, every kept invoice that references
  # an unlocked entry, with the entries and what the first cutover does with
  # them. The record is checked in at spec/fixtures/timekeeping/seed_disposition.yml.
  #
  # Pure: it builds and compares plain hashes and touches no database.
  module SeedDisposition
    # A committed reservation by that invoice at the first cutover. Every
    # unlocked link gets it: without a reservation, a second invoice could take
    # the entry after cutover.
    RESERVE = "reserve"

    module_function

    # by_company: { company_name => { classification:, invoice_numbers: } },
    # where classification is the result of Timekeeping::Preflight.classify
    # and invoice_numbers maps invoice id to invoice number.
    #
    # Companies, invoice numbers and entry ids are sorted, and the record holds
    # no time of generation, so the same seed always gives the same file.
    def record(by_company, as_of:)
      companies = by_company.sort.to_h do |company_name, company|
        [company_name, invoices_with_unlocked_links(company)]
      end

      { "as_of" => as_of.to_s, "companies" => companies }
    end

    # Returns a list of problems, empty when the recorded disposition and the
    # live one are exactly equal and every listed invoice is reserved.
    def verify(recorded:, live:)
      problems = []
      problems << "the recorded seed disposition lists no invoices" if invoice_count(recorded).zero?
      problems.concat(unreserved_invoices(recorded))
      if recorded["as_of"] != live["as_of"]
        problems << "recorded as_of #{recorded['as_of'].inspect} differs from live #{live['as_of'].inspect}"
      end
      problems.concat(invoice_differences(recorded, live))
      problems << "the recorded seed disposition differs from the live one" if problems.empty? && recorded != live
      problems
    end

    def invoices_with_unlocked_links(company)
      invoice_numbers = company.fetch(:invoice_numbers)

      company.fetch(:classification).fetch(:unlocked_links)
        .group_by { |link| invoice_numbers.fetch(link[:invoice_id]) }
        .sort.to_h do |invoice_number, links|
          [invoice_number, { "entry_ids" => links.pluck(:entry_id).sort, "disposition" => RESERVE }]
        end
    end

    def invoice_count(disposition)
      companies(disposition).values.sum { |invoices| invoices.to_h.size }
    end

    def unreserved_invoices(disposition)
      companies(disposition).flat_map do |company_name, invoices|
        invoices.to_h.filter_map do |invoice_number, listing|
          disposition_value = listing.to_h["disposition"]
          next if disposition_value == RESERVE

          "#{company_name} #{invoice_number}: disposition #{disposition_value.inspect}, expected #{RESERVE.inspect}"
        end
      end
    end

    # Compared per company and per invoice, so a listing filed under the wrong
    # company or invoice is reported where it is wrong.
    def invoice_differences(recorded, live)
      recorded_companies = companies(recorded)
      live_companies = companies(live)

      (recorded_companies.keys | live_companies.keys).sort.flat_map do |company_name|
        recorded_invoices = recorded_companies.fetch(company_name, {}).to_h
        live_invoices = live_companies.fetch(company_name, {}).to_h

        (recorded_invoices.keys | live_invoices.keys).sort.filter_map do |invoice_number|
          recorded_ids = recorded_invoices.dig(invoice_number, "entry_ids")
          live_ids = live_invoices.dig(invoice_number, "entry_ids")
          next if recorded_ids == live_ids

          "#{company_name} #{invoice_number}: recorded entry ids #{recorded_ids.inspect}, live #{live_ids.inspect}"
        end
      end
    end

    def companies(disposition)
      disposition.to_h.fetch("companies", nil).to_h
    end
  end
end
