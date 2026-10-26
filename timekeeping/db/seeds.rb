# frozen_string_literal: true

# A database loaded from db/schema.rb has tables but no rows. Without the
# admission row every entry write is refused, so create it at generation 1.
Timekeeping::Admission.ensure_initial!
