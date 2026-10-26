# frozen_string_literal: true

# The stored answer to one successful entry snapshot delivery, scoped by the
# batch's sorted company ids, the delivering service and the Idempotency-Key.
# Timekeeping::ProjectionConsumer reads and writes it.
class EntrySnapshotReceipt < ApplicationRecord
end
