# frozen_string_literal: true

module Timekeeping
  # The first-cutover pre-flight of docs/architecture/timekeeping-soa.md
  # section 10.4: sorts legacy time entries by how the `locked` flag and the
  # invoice links that reference them disagree, so the cutover lists every
  # legacy state instead of normalizing it quietly.
  #
  # Pure: it reads plain hashes and touches no database.
  module Preflight
    LISTS = %i[active orphans conflicts retained relock_releases unlocked_links].freeze

    # For each entry, the first row whose condition holds names its list; an
    # entry no row matches (unlocked and held by no kept invoice) is free and
    # goes in no list.
    CLASSIFICATION_TABLE = [
      [->(facts) { facts[:kept].size >= 2 }, :conflicts],
      [->(facts) { facts[:locked] && facts[:kept].size == 1 }, :active],
      [->(facts) { !facts[:locked] && facts[:kept].size == 1 }, :unlocked_links],
      [->(facts) { facts[:locked] && facts[:linked_invoices].empty? }, :orphans],
      # More than one plausible historical owner, whether or not it is locked.
      [->(facts) { facts[:kept].empty? && facts[:discarded_non_drafts].size >= 2 }, :conflicts],
      [->(facts) { facts[:locked] && facts[:kept].empty? && facts[:discarded_non_drafts].size == 1 }, :retained],
      # A discarded draft keeps its entries locked only through the re-lock its
      # discard callbacks trigger.
      [
        ->(facts) {
          facts[:locked] && facts[:kept].empty? && facts[:discarded_non_drafts].empty? &&
            facts[:discarded_drafts].any?
        },
        :relock_releases
      ]
    ].freeze

    module_function

    # entries: [{ id:, locked: }]
    # links: [{ entry_id:, invoice_id:, draft:, discarded: }], one per invoice
    # reference, from direct line items and grouped line-item join rows alike.
    #
    # Returns a hash of the LISTS. Each list holds entry ids, except
    # unlocked_links, which holds { entry_id:, invoice_id: } pairs because a
    # disposition is recorded per invoice.
    def classify(entries:, links:)
      links_by_entry = links.group_by { |link| link[:entry_id] }
      result = LISTS.index_with { [] }

      entries.each do |entry|
        facts = entry_facts(entry, links_by_entry.fetch(entry[:id], []))
        list = list_for(facts)
        next unless list

        result[list] << (list == :unlocked_links ? { entry_id: entry[:id], invoice_id: facts[:kept].first } : entry[:id])
      end

      result
    end

    def list_for(facts)
      CLASSIFICATION_TABLE.find { |condition, _list| condition.call(facts) }&.last
    end

    # Invoice ids are de-duplicated, so an entry referenced by both a direct
    # line and a grouped line of one invoice has one owner, not two.
    def entry_facts(entry, links)
      kept, discarded = links.partition { |link| !link[:discarded] }
      discarded_drafts, discarded_non_drafts = discarded.partition { |link| link[:draft] }

      {
        locked: entry[:locked],
        linked_invoices: invoice_ids(links),
        kept: invoice_ids(kept),
        discarded_non_drafts: invoice_ids(discarded_non_drafts),
        discarded_drafts: invoice_ids(discarded_drafts)
      }
    end

    def invoice_ids(links)
      links.pluck(:invoice_id).uniq
    end
  end
end
