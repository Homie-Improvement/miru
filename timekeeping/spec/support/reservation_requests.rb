# frozen_string_literal: true

require_relative "../../../spec/support/timekeeping/contract"

# Requests to the reservation routes, built from contracts/timekeeping/reservations.yml
# so a path or route change is made once. The path company and the credential
# are always the caller's to name: cross-company specs depend on sending one
# company's token to another company's path.
module ReservationRequests
  # Posts to a reservation route with the current generation merged into the
  # body (a body that carries its own generation keeps it). A nil credential
  # sends no Authorization header. Path params fill the route's other
  # placeholders, such as invoice_id for mark_billed and agent_id for
  # detach_entries.
  def reservation_post(route, company:, credential:, body: {}, **path_params)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{credential}" if credential
    post reservation_route_path(route, company_id: company, **path_params),
         params: JSON.generate({ "generation" => timekeeping_arrange.current_generation }.merge(body)), headers: headers
    response
  end

  def reservation_routes
    TimekeepingContract.load(:reservations).fetch("routes").keys
  end

  private

    def reservation_route_path(route, **params)
      TimekeepingContract.load(:reservations).dig("routes", route.to_s, "path")
        .gsub(/\{(\w+)\}/) { params.fetch(Regexp.last_match(1).to_sym) }
    end
end

# Counts of every table a reservation operation or service command writes, to
# show a refused or failed one left nothing behind.
module ReservationRowCounts
  def reservation_row_counts
    { reservations: Reservation.count, operations: InvoiceOperation.count, audit_events: AuditEvent.count,
      outbox_snapshots: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
  end
end

RSpec.configure do |config|
  config.include ReservationRequests, type: :request
  config.include ReservationRowCounts
end
