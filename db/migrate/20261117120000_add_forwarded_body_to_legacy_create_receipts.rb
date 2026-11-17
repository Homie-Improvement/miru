# frozen_string_literal: true

# Stores, with each legacy create receipt, the body a forwarded create of the
# same request would send to Timekeeping. The first cutover carries the
# receipt into Timekeeping's receipts, which match a retry by a hash of the
# body as sent, so the receipt must hold that body exactly.
#
# The body holds defaults read from current state, such as the project's
# billing default, so it cannot be rebuilt later from the request values.
# It is text, not jsonb, because jsonb does not keep key order and
# Timekeeping's hash depends on it. Receipts written before this column have
# none.
class AddForwardedBodyToLegacyCreateReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :legacy_create_receipts, :forwarded_body, :text
  end
end
