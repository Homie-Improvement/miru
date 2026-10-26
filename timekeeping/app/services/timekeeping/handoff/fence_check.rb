# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The check every handoff write makes before it replaces data: entry writes
    # must be fenced, or a write admitted after the export could be lost or
    # overtaken. Reading the admission row FOR SHARE makes an admit! wait until
    # the calling transaction has committed or rolled back.
    module FenceCheck
      module_function

      # Raises Store::Error, naming the refused action, when the admission row
      # is missing or admits a generation. Call it inside the transaction it
      # protects.
      def require_fenced!(connection, action)
        rows = connection.select_rows(ApplicationRecord.sanitize_sql_array(
          ["SELECT generation FROM admission WHERE id = ? FOR SHARE", Admission::SINGLETON_ID]
        ))
        raise Store::Error, "refusing to #{action}: the admission row is missing" if rows.empty?
        return if rows.first.first.nil?

        raise Store::Error, "refusing to #{action} while entry writes are admitted; fence admission first"
      end
    end
  end
end
