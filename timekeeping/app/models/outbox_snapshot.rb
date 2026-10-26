# frozen_string_literal: true

# The id column holds the entry's id, so the row is keyed by its position.
class OutboxSnapshot < ApplicationRecord
  self.primary_key = "outbox_position"

  # Takes the outbox insert lock (Timekeeping::WriteSteps::OUTBOX_LOCK_KEY)
  # for the rest of the calling transaction, so a writer that inserts outbox
  # rows outside WriteSteps.write_outbox still commits positions in the order
  # they were drawn.
  def self.lock_for_insert!
    connection.execute(sanitize_sql_array(["SELECT pg_advisory_xact_lock(?)", Timekeeping::WriteSteps::OUTBOX_LOCK_KEY]))
  end

  # Rails sends id= to the primary key, which would put the entry's id into
  # outbox_position and leave the id column null. outbox_position comes only
  # from its sequence, so id= writes the id column. The id reader still
  # answers the primary key, which record equality and hashing rely on; read
  # the entry's id with id_value.
  def id=(value)
    _write_attribute("id", value)
  end

  # company_id => the enqueued_at of that company's oldest unsent row. Each
  # company's minimum is taken over its own rows only, so one company's backlog
  # is never reported under another. A company with nothing unsent is absent.
  def self.oldest_unsent_by_company
    where(sent_at: nil).group(:company_id).minimum(:enqueued_at)
  end
end
