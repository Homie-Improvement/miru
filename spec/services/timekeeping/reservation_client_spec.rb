# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReservationClient do
  it "two companies' prepares each carry their own path and a fresh one-operation service token, never the shared TIMEKEEPING_SERVICE_TOKEN" do
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      with_timekeeping_service_token do |shared_token|
        fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
        generation = TimekeepingOwnership.current.generation
        fake.generation = generation
        # Real company rows, so the ids the client sends are the monolith's own.
        companies = Array.new(2) do
          company_id = create(:company).id
          user_id = fake.add_user(company_id:, role: "admin")
          project_id = fake.add_project(company_id:)
          entry = fake.add_entry(company_id:, user_id:, project_id:)
          # A second invoice of the same company needs its own entry: the first
          # invoice's prepare holds this one provisionally.
          later_entry = fake.add_entry(company_id:, user_id:, project_id:)
          { company_id:, entry_id: entry["id"], later_entry_id: later_entry["id"] }
        end
        request_for = lambda do |company, invoice_id, entry_key = :entry_id|
          Invoices::ReservationRequest.new(
            company_id: company[:company_id], invoice_id:, operation_id: SecureRandom.uuid,
            generation:, disposition: "active", entries: [company[entry_key]]
          )
        end
        # One client instance serves both companies, so nothing it remembers may cross between them.
        client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
        first_request = request_for.call(companies[0], 501)

        outcomes = [
          client.prepare(first_request),
          client.prepare(request_for.call(companies[1], 502)),
          client.prepare(request_for.call(companies[0], 503, :later_entry_id))
        ]
        expect(outcomes.map(&:state)).to eq(%w[prepared prepared prepared])

        sent = fake.requests
        expect(sent.size).to eq(3)
        expected_companies = [companies[0], companies[1], companies[0]].pluck(:company_id)
        sent.zip(expected_companies).each do |request, company_id|
          # "Build the path from the request's stored company_id."
          expect(request[:path]).to eq("/v1/companies/#{company_id}/reservations/prepare")
          token = TimekeepingContract::Wire.bearer(request[:headers])
          # "The client never sends the shared `TIMEKEEPING_SERVICE_TOKEN` and never caches a token."
          expect(token).not_to eq(shared_token)
          # "The default mints a new `Timekeeping::ServiceToken` on each call, for the request's company and the one operation."
          claims = Timekeeping::ServiceToken.verify(token, public_key: timekeeping_key_pair.public_key)
          expect(claims.company_id).to eq(company_id)
          expect(claims.operations).to eq(["reservations.prepare"])
        end

        tokens = sent.map { |request| TimekeepingContract::Wire.bearer(request[:headers]) }
        expect(tokens.uniq.size).to eq(3)
        expect(fake.reservations_for(companies[0][:entry_id]).pluck("invoice_id")).to eq([501])
        expect(fake.reservations_for(companies[1][:entry_id]).pluck("invoice_id")).to eq([502])
        expect(fake.reservations_for(companies[0][:later_entry_id]).pluck("invoice_id")).to eq([503])

        # Sending the same request again mints a new token rather than reusing the first.
        client.prepare(first_request)
        repeat = fake.requests.last
        expect(repeat[:path]).to eq("/v1/companies/#{companies[0][:company_id]}/reservations/prepare")
        repeat_token = TimekeepingContract::Wire.bearer(repeat[:headers])
        expect(repeat_token).not_to eq(tokens.first)
        expect(repeat_token).not_to eq(shared_token)
      end
    end
  end
end

RSpec.describe Timekeeping::ReservationClient do
  it "a prepare whose service token cannot be minted answers retryable and sends no request, not even with the shared token" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = 4
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry = fake.add_entry(company_id:, user_id:, project_id:)
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 301, operation_id: SecureRandom.uuid,
      generation: 4, disposition: "active", entries: [entry["id"]]
    )

    # With no private key the default credential cannot mint a token.
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => nil) do
      with_timekeeping_service_token do
        client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))

        outcome = client.prepare(request)

        # "Nothing outside this table maps to success."
        expect(outcome.state).to eq("retryable")
        # "The client never sends the shared `TIMEKEEPING_SERVICE_TOKEN` and never caches a token."
        expect(fake.requests).to be_empty
        expect(fake.entry_locked?(entry["id"])).to be(false)
      end
    end
  end
end

RSpec.describe Timekeeping::ReservationClient do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "a prepare that arrives after its abort reserves nothing, and a repeated abort changes nothing" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "employee")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:)["id"]
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 501, operation_id: SecureRandom.uuid,
      generation: fake.generation, disposition: "active", entries: [entry_id]
    )

    expect(client.abort(request).state).to eq("aborted")

    # "A prepare that arrives after its abort reserves nothing, including a delayed copy that arrives after a conflict clears"
    late = client.prepare(request)

    expect(late.state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])

    expect(client.abort(request).state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end
end

RSpec.describe Timekeeping::ReservationClient do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "an abort refused by a conflict stays retryable until a delayed prepare copy sent after the conflict clears is aborted, leaving nothing reserved" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "employee")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:)["id"]
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    build_request = lambda do |invoice_id|
      Invoices::ReservationRequest.new(
        company_id:, invoice_id:, operation_id: SecureRandom.uuid,
        generation: fake.generation, disposition: "active", entries: [entry_id]
      )
    end
    other = build_request.call(601)
    aborted_save = build_request.call(602)

    expect(client.prepare(other).state).to eq("prepared")

    # "A replay refused with 409 conflict stores nothing in the service, so a delayed copy could still reserve later. In that case abort answers retryable with reason `conflict`, and the row is retried until the abort makes the operation terminal."
    refused_abort = client.abort(aborted_save)
    expect(refused_abort.state).to eq("retryable")
    expect(refused_abort.reason).to eq("conflict")

    expect(client.abort(other).state).to eq("aborted")

    delayed_copy = client.prepare(aborted_save)
    expect(delayed_copy.state).to eq("prepared")
    expect(fake.entry_locked?(entry_id)).to be(true)

    expect(client.abort(aborted_save).state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end

  it "the same holds when the conflicting holder is a committed invoice that later releases the entry" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:)["id"]
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    build = lambda do |invoice_id, entries|
      Invoices::ReservationRequest.new(
        company_id:, invoice_id:, operation_id: SecureRandom.uuid, generation: fake.generation,
        disposition: "active", entries:
      )
    end
    holder = build.call(900, [entry_id])
    expect(client.prepare(holder).state).to eq("prepared")
    expect(client.commit(holder).state).to eq("committed")
    request = build.call(501, [entry_id])

    # "In that case abort answers retryable with reason `conflict`, and the row is retried until the abort makes the operation terminal."
    refused_abort = client.abort(request)
    expect(refused_abort.state).to eq("retryable")
    expect(refused_abort.reason).to eq("conflict")

    # Invoice 900 commits again with no entries, which releases the entry.
    release = build.call(900, [])
    expect(client.prepare(release).state).to eq("prepared")
    expect(client.commit(release).state).to eq("committed")
    expect(fake.reservations_for(entry_id)).to eq([])

    expect(client.prepare(request).state).to eq("prepared")
    expect(fake.entry_locked?(entry_id)).to be(true)

    expect(client.abort(request).state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end
end

RSpec.describe Timekeeping::ReservationClient do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "commit replays a byte-equal prepare in canonical entry order and a redelivered commit reserves nothing twice" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "employee")
    project_id = fake.add_project(company_id:)
    first_entry = fake.add_entry(company_id:, user_id:, project_id:)["id"]
    second_entry = fake.add_entry(company_id:, user_id:, project_id:)["id"]
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 701, operation_id: SecureRandom.uuid,
      generation: fake.generation, disposition: "active", entries: [second_entry, first_entry]
    )

    expect(client.prepare(request).state).to eq("prepared")
    # "`commit` posts commit, then replays prepare and answers the replayed state."
    expect(client.commit(request).state).to eq("committed")
    expect(client.commit(request).state).to eq("committed")

    # "The replay body is built only from the request's stored fields, in canonical entry order. The fake answers `key_reused` to any other body."
    prepare_bodies = fake.requests.filter_map { |sent| sent[:body] if sent[:path].end_with?("/reservations/prepare") }
    expect(prepare_bodies.size).to be >= 2
    expect(prepare_bodies.uniq.size).to eq(1)
    expect(prepare_bodies.first["entries"]).to eq([first_entry, second_entry].sort)
    expect(prepare_bodies.first["generation"]).to eq(fake.generation)

    [first_entry, second_entry].each do |entry_id|
      expect(fake.reservations_for(entry_id)).to eq([{ "invoice_id" => 701, "state" => "committed" }])
      expect(fake.entry_locked?(entry_id)).to be(true)
    end
  end
end

RSpec.describe Timekeeping::ReservationClient do
  it "a prepare carrying a token minted for another company is refused by the service, answers retryable and reserves nothing" do
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
      generation = TimekeepingOwnership.current.generation
      fake.generation = generation
      company = create(:company)
      other_company = create(:company)
      entry = fake.add_entry(company_id: company.id, user_id: 1, project_id: 1)
      wrong_company_credential = lambda do |company_id:, operation:|
        Timekeeping::ServiceToken.mint(company_id: other_company.id, operations: [operation])
      end
      client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil),
                                   credential: wrong_company_credential)
      request = Invoices::ReservationRequest.new(company_id: company.id, invoice_id: 601, operation_id: SecureRandom.uuid,
                                                 generation:, disposition: "active", entries: [entry["id"]])

      outcome = client.prepare(request)

      # "A 401, 403 or 404, an unknown status, or a missing or unknown state maps to retryable."
      # "Nothing outside this table maps to success."
      expect(outcome.state).to eq("retryable")
      expect(fake.requests.pluck(:path)).to eq(["/v1/companies/#{company.id}/reservations/prepare"])
      expect(fake.entry_locked?(entry["id"])).to be(false)
      expect(fake.reservations_for(entry["id"])).to eq([])
    end
  end
end

RSpec.describe Timekeeping::ReservationClient do
  it "a prepare for one company naming another company's entry is refused with not_found and leaves that entry unreserved" do
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
      generation = TimekeepingOwnership.current.generation
      fake.generation = generation
      company = create(:company)
      other_company = create(:company)
      foreign_entry = fake.add_entry(company_id: other_company.id, user_id: 2, project_id: 2)
      client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
      request = Invoices::ReservationRequest.new(company_id: company.id, invoice_id: 701, operation_id: SecureRandom.uuid,
                                                 generation:, disposition: "active", entries: [foreign_entry["id"]])

      outcome = client.prepare(request)

      # "A 409 `conflict` maps to refused, with `[{entry_id:, reason:}]`."
      expect(outcome.state).to eq("refused")
      expect(outcome.conflicts).to eq([{ entry_id: foreign_entry["id"], reason: "not_found" }])
      expect(fake.entry_locked?(foreign_entry["id"])).to be(false)
      expect(fake.reservations_for(foreign_entry["id"])).to eq([])
    end
  end
end

RSpec.describe Timekeeping::ReservationClient, "prepare and commit" do
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:client) { described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)) }
  let(:company_id) { fake.add_company }
  let(:entry_id) do
    user_id = fake.add_user(company_id:, role: "admin")
    fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
  end

  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "prepare then commit through the client reserves the entry as committed on the fake with one operation" do
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 501, operation_id: SecureRandom.uuid, generation: fake.generation,
      disposition: "active", entries: [entry_id]
    )

    prepared = client.prepare(request)
    expect(prepared).to be_a(Invoices::ReservationOutcome)
    expect(prepared.state).to eq("prepared")
    expect(fake.entry_locked?(entry_id)).to be(true)

    # "`commit` posts commit, then replays prepare and answers the replayed state."
    committed = client.commit(request)
    expect(committed.state).to eq("committed")
    expect(fake.reservations_for(entry_id)).to eq([{ "invoice_id" => 501, "state" => "committed" }])

    paths = fake.requests.pluck(:path)
    expect(paths).to all(start_with("/v1/companies/#{company_id}/reservations/"))
    prepare_bodies = fake.requests.filter_map { |logged| logged[:body] if logged[:path].end_with?("/reservations/prepare") }
    expect(prepare_bodies.pluck("operation_id").uniq).to eq([request.operation_id])
    expect(prepare_bodies.uniq.size).to eq(1)
  end
end

RSpec.describe Timekeeping::ReservationClient, "conflict mapping" do
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:client) { described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)) }
  let(:company_id) { fake.add_company }
  let(:entry_id) do
    user_id = fake.add_user(company_id:, role: "admin")
    fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
  end

  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "a 409 conflict on prepare maps to refused with the fake's conflict reason" do
    fake.add_reservation(entry_id:, invoice_id: 900, state: "committed", disposition: "active")
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 501, operation_id: SecureRandom.uuid, generation: fake.generation,
      disposition: "active", entries: [entry_id]
    )

    outcome = client.prepare(request)

    # "a 409 `conflict` maps to refused with conflicts"
    expect(outcome.state).to eq("refused")
    expect(outcome.conflicts).to eq([{ entry_id:, reason: "on_another_invoice" }])
    expect(fake.reservations_for(entry_id)).to eq([{ "invoice_id" => 900, "state" => "committed" }])
  end
end

RSpec.describe Timekeeping::ReservationClient, "retryable 409 mapping" do
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:client) { described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)) }
  let(:company_id) { fake.add_company }
  let(:entry_id) do
    user_id = fake.add_user(company_id:, role: "admin")
    fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
  end

  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "unresolved_operation and stale_generation answers map to retryable with that reason" do
    build = lambda do |generation: fake.generation|
      Invoices::ReservationRequest.new(
        company_id:, invoice_id: 501, operation_id: SecureRandom.uuid, generation:,
        disposition: "active", entries: [entry_id]
      )
    end
    expect(client.prepare(build.call).state).to eq("prepared")

    # "`unresolved_operation` and `stale_generation` map to retryable"
    unresolved = client.prepare(build.call)
    expect(unresolved.state).to eq("retryable")
    expect(unresolved.reason).to eq("unresolved_operation")

    stale = client.prepare(build.call(generation: fake.generation - 1))
    expect(stale.state).to eq("retryable")
    expect(stale.reason).to eq("stale_generation")
  end
end

RSpec.describe Timekeeping::ReservationClient, "mark_billed" do
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:client) { described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)) }
  let(:company_id) { fake.add_company }
  let(:entry_id) do
    user_id = fake.add_user(company_id:, role: "admin")
    fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
  end

  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "mark_billed with an integer billed answer is committed with the billed count, and a 409 conflict is refused" do
    build = lambda do
      Invoices::ReservationRequest.new(
        company_id:, invoice_id: 501, operation_id: SecureRandom.uuid, generation: fake.generation,
        disposition: "active", entries: [entry_id]
      )
    end
    reserved = build.call
    expect(client.prepare(reserved).state).to eq("prepared")
    expect(client.commit(reserved).state).to eq("committed")

    # "A 200 mark_billed answer with an integer `billed` maps to `committed` with `counts: { billed: }`."
    billed = client.mark_billed(build.call)
    expect(billed.state).to eq("committed")
    expect(billed.counts).to eq({ billed: 1 })
    expect(fake.requests.last[:path]).to eq("/v1/companies/#{company_id}/invoices/501/mark-billed")
    expect(fake.stored_entry(entry_id)["bill_status"]).to eq("billed")

    # "A 409 `conflict` maps to refused, with `[{entry_id:, reason:}]`." holds for billing too.
    billing_conflict = lambda do |_method, _path, headers:, body: nil|
      TimekeepingContract::Response.new(status: 409, body: {
                                          "reason" => "conflict",
                                          "conflicts" => [{ "entry_id" => entry_id, "reason" => "on_another_invoice" }]
                                        })
    end
    refused = described_class.new(http: billing_conflict).mark_billed(build.call)
    expect(refused.state).to eq("refused")
    expect(refused.conflicts).to eq([{ entry_id:, reason: "on_another_invoice" }])
  end
end

RSpec.describe Timekeeping::ReservationClient, "admit" do
  it "admit answers from the local claim check and sends no request to the service" do
    sent = []
    http = lambda do |method, path, headers:, body: nil|
      sent << [method, path]
      TimekeepingContract::Response.new(status: 500, body: {})
    end
    company = create(:company)
    request = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: 501, operation_id: SecureRandom.uuid, generation: 1,
      disposition: "active", entries: []
    )

    # "The client delegates it to `Invoices::LegacyReservations#admit`, a local claim check over `Invoices::EntryClaims` that writes nothing and sends no request."
    outcome = described_class.new(http:, credential: ->(company_id:, operation:) { "unused" }).admit(request)

    expect(outcome.state).to eq("prepared")
    expect(sent).to eq([])
  end
end

RSpec.describe Timekeeping::ReservationClient, "an abort request that fails after a reserving replay" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "`abort` replays prepare, posts abort, replays prepare again and answers that state."
  # "A 5xx, a `ReservationHttp::Error` or an unparseable body maps to retryable."
  it "an abort whose abort request answers 503 after its replay reserved the entry is retryable, not aborted" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:).fetch("id")
    healthy = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
    abort_unavailable = Object.new
    abort_unavailable.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      if path.end_with?("/reservations/abort")
        TimekeepingContract::Response.new(status: 503, body: { "reason" => "unavailable" })
      else
        healthy.call(method, path, headers:, body:)
      end
    end
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 701, operation_id: SecureRandom.uuid,
      generation: fake.generation, disposition: "active", entries: [entry_id]
    )

    # The first replay itself reserves the entry, because the original prepare never arrived.
    failed = described_class.new(http: abort_unavailable).abort(request)

    expect(failed.state).to eq("retryable")
    expect(fake.entry_locked?(entry_id)).to be(true)

    # The outbox retries the row; the retried abort drops the reservation the replay made.
    expect(described_class.new(http: healthy).abort(request).state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end
end

RSpec.describe Timekeeping::ReservationClient, "a commit for an unknown operation" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "`commit` posts commit, then replays prepare and answers the replayed state. A 404 on commit maps to retryable."
  it "a commit for an operation the service never stored answers retryable and reserves nothing" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:).fetch("id")
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 801, operation_id: SecureRandom.uuid,
      generation: fake.generation, disposition: "active", entries: [entry_id]
    )

    outcome = client.commit(request)

    expect(outcome.state).to eq("retryable")
    # A replay after the 404 would store a new prepared operation and reserve the entry.
    expect(fake.requests.count { |sent| sent[:path].end_with?("/reservations/prepare") }).to eq(0)
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end
end

# One table per route of every answer the service can give outside the
# contract's mapping table, beside the well-formed answer that must still map.
RSpec.describe Timekeeping::ReservationClient, "answers outside the mapping table" do
  operation_id = "6f1d2c3b-4a5e-4f60-8b7a-9c0d1e2f3a4b"

  # The default credential mints a real token, so the key must be loadable or
  # every row would be retryable for the wrong reason.
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # answer is a [status, body] pair the service sends back, or an exception
  # the transport raises in place of an answer.
  def client_answering(answer)
    http = Object.new
    http.define_singleton_method(:call) do |_method, _path, headers: {}, body: nil|
      raise answer if answer.is_a?(Exception)

      TimekeepingContract::Response.new(status: answer[0], body: answer[1])
    end
    described_class.new(http:)
  end

  def table_request(operation_id)
    Invoices::ReservationRequest.new(company_id: 41, invoice_id: 901, operation_id:,
                                     generation: 1, disposition: "active", entries: [7])
  end

  # "Nothing outside this table maps to success."
  # "A 401, 403 or 404, an unknown status, or a missing or unknown state maps to retryable."
  # "A 5xx, a `ReservationHttp::Error` or an unparseable body maps to retryable."
  describe "prepare" do
    {
      "a 200 with the unknown state reserved_everything" => [200, { "operation_id" => operation_id, "state" => "reserved_everything" }],
      "a 200 with the unknown state reserved" => [200, { "operation_id" => operation_id, "state" => "reserved" }],
      "a 200 with the unknown state done" => [200, { "operation_id" => operation_id, "state" => "done" }],
      "a 200 with no state" => [200, { "operation_id" => operation_id }],
      "a 200 with entries but no state" => [200, { "operation_id" => operation_id, "entries" => [] }],
      "a 200 whose body is not a JSON object" => [200, "not a json object"],
      "a 200 with no body" => [200, nil],
      "a 401" => [401, { "reason" => "unauthorized" }],
      "a 403" => [403, { "reason" => "forbidden" }],
      "a 404" => [404, { "reason" => "not_found" }],
      "an unknown status carrying a known state" => [418, { "state" => "prepared" }],
      "an unknown status with an empty body" => [418, {}],
      "a 503 carrying a known state" => [503, { "state" => "prepared" }],
      "a 503" => [503, { "reason" => "unavailable" }],
      "a 409 conflict with an empty conflicts list" => [409, { "reason" => "conflict", "conflicts" => [] }],
      "a 409 conflict whose item has no entry_id" => [409, { "reason" => "conflict",
                                                              "conflicts" => [{ "reason" => "on_another_invoice" }] }],
      "a 409 conflict with no conflicts key" => [409, { "reason" => "conflict" }],
      "a transport error" => Timekeeping::ReservationHttp::Error.new("prepare failed: Timeout::Error")
    }.each do |answer_name, answer|
      it "#{answer_name} is retryable, never a success" do
        outcome = client_answering(answer).prepare(table_request(operation_id))

        expect(outcome.state).to eq("retryable")
        expect(outcome.reason).to be_nil
        expect(outcome.conflicts).to eq([])
      end
    end

    # The well-formed row still maps as stated, so the rows above are not retryable only by default.
    # "A 409 `conflict` maps to refused, with `[{entry_id:, reason:}]`."
    it "a well-formed 409 conflict is refused with its conflicts" do
      answer = [409, { "reason" => "conflict", "conflicts" => [{ "entry_id" => 7, "reason" => "on_another_invoice" }] }]

      outcome = client_answering(answer).prepare(table_request(operation_id))

      expect(outcome.state).to eq("refused")
      expect(outcome.conflicts).to eq([{ entry_id: 7, reason: "on_another_invoice" }])
    end
  end

  # "A 200 mark_billed answer with an integer `billed` maps to `committed` with `counts: { billed: }`."
  # "Nothing outside this table maps to success."
  describe "mark_billed" do
    {
      "a 200 with the string billed count 3" => [200, { "billed" => "3" }],
      "a 200 with the string billed count 1" => [200, { "billed" => "1" }],
      "a 200 with no billed count" => [200, {}],
      "a 200 with a null billed count" => [200, { "billed" => nil }],
      "a 503 with an integer billed count" => [503, { "billed" => 3 }]
    }.each do |answer_name, answer|
      it "#{answer_name} is retryable, not committed" do
        outcome = client_answering(answer).mark_billed(table_request(operation_id))

        expect(outcome.state).to eq("retryable")
        expect(outcome.reason).to be_nil
        expect(outcome.counts).to eq({})
      end
    end

    # The well-formed row still maps as stated, so the rows above are not retryable only by default.
    it "a 200 with an integer billed count is committed with that count" do
      outcome = client_answering([200, { "billed" => 1 }]).mark_billed(table_request(operation_id))

      expect(outcome.state).to eq("committed")
      expect(outcome.counts).to eq({ billed: 1 })
    end
  end
end
