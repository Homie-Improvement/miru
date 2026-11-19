# frozen_string_literal: true

module Timekeeping
  module Handoff
    # Opens the settle step for the outgoing generation and reports what the
    # handoff runner needs to know about it (docs/architecture/timekeeping-soa.md
    # section 10.5).
    module Settle
      # settling is read back from the row rather than assumed, because
      # begin_settling! changes nothing when writes are still admitted, the
      # generation was already stopped, or a newer generation is settling.
      # prepared_operations counts the invoice operations not yet committed or
      # aborted; settle ends when it reaches zero.
      def self.call(generation:)
        Admission.begin_settling!(generation:)
        { settling: Admission.current.settling_generation == generation,
          prepared_operations: InvoiceOperation.where(state: "prepared").count }
      end
    end
  end
end
