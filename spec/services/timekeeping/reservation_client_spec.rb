# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReservationClient do
  it "two companies' prepares each carry their own path and a fresh one-operation service token, never the shared TIMEKEEPING_SERVICE_TOKEN" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = 7
    companies = Array.new(2) do
      company_id = fake.add_company
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
        generation: 7, disposition: "active", entries: [company[entry_key]]
      )
    end

    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      with_timekeeping_service_token do |shared_token|
        # One client instance serves both companies, so nothing it remembers may cross between them.
        client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))

        outcomes = [
          client.prepare(request_for.call(companies[0], 101)),
          client.prepare(request_for.call(companies[1], 201)),
          client.prepare(request_for.call(companies[0], 102, :later_entry_id))
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
      end
    end
  end
end

RSpec.describe Timekeeping::ReservationClient do
  it "malformed, unauthorized or unknown service answers to prepare and mark_billed map to retryable and never to success" do
    request = Invoices::ReservationRequest.new(
      company_id: 41, invoice_id: 501, operation_id: SecureRandom.uuid,
      generation: 3, disposition: "active", entries: [9001]
    )
    client_answering = lambda do |status, answer_body|
      http = ->(_method, _path, headers:, body: nil) { TimekeepingContract::Response.new(status:, body: answer_body) }
      described_class.new(http:, credential: ->(company_id:, operation:) { "test-credential-#{company_id}-#{operation}" })
    end

    # "Nothing outside this table maps to success."
    # "A 401, 403 or 404, an unknown status, or a missing or unknown state maps to retryable."
    prepare_answers = [
      [200, { "operation_id" => request.operation_id, "state" => "reserved_everything" }],
      [200, { "operation_id" => request.operation_id }],
      [200, "not a json object"],
      [401, { "reason" => "unauthorized" }],
      [403, { "reason" => "forbidden" }],
      [404, { "reason" => "not_found" }],
      [418, { "state" => "prepared" }],
      [503, { "state" => "prepared" }],
      [409, { "reason" => "conflict", "conflicts" => [] }],
      [409, { "reason" => "conflict", "conflicts" => [{ "reason" => "on_another_invoice" }] }]
    ]
    prepare_answers.each do |status, body|
      outcome = client_answering.call(status, body).prepare(request)
      expect(outcome.state).to eq("retryable"), "prepare answered #{status} #{body.inspect} gave #{outcome.state}"
    end

    # "A 200 mark_billed answer with an integer `billed` maps to `committed` with `counts: { billed: }`."
    [{ "billed" => "3" }, {}, { "billed" => nil }].each do |body|
      outcome = client_answering.call(200, body).mark_billed(request)
      expect(outcome.state).to eq("retryable"), "mark_billed answered #{body.inspect} gave #{outcome.state}"
    end

    # The well-formed rows still map as the issue states, so the cases above are not retryable only by default.
    # "A 409 `conflict` maps to refused, with `[{entry_id:, reason:}]`."
    refused = client_answering.call(409, { "reason" => "conflict",
                                           "conflicts" => [{ "entry_id" => 9001, "reason" => "on_another_invoice" }] })
      .prepare(request)
    expect(refused.state).to eq("refused")
    expect(refused.conflicts).to eq([{ entry_id: 9001, reason: "on_another_invoice" }])
    billed = client_answering.call(200, { "billed" => 1 }).mark_billed(request)
    expect(billed.state).to eq("committed")
    expect(billed.counts).to eq({ billed: 1 })
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
  it "sends each company's prepare to its own company path with a freshly minted token for that company and the one operation" do
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      with_timekeeping_service_token do |shared_token|
        fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
        generation = TimekeepingOwnership.current.generation
        fake.generation = generation
        client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
        company_a = create(:company)
        company_b = create(:company)
        entry_a = fake.add_entry(company_id: company_a.id, user_id: 1, project_id: 1)
        entry_b = fake.add_entry(company_id: company_b.id, user_id: 2, project_id: 2)
        later_entry_a = fake.add_entry(company_id: company_a.id, user_id: 1, project_id: 1)
        request_for = lambda do |company, invoice_id, entry|
          Invoices::ReservationRequest.new(company_id: company.id, invoice_id:, operation_id: SecureRandom.uuid,
                                           generation:, disposition: "active", entries: [entry["id"]])
        end

        outcomes = [
          client.prepare(request_for.call(company_a, 501, entry_a)),
          client.prepare(request_for.call(company_b, 502, entry_b)),
          client.prepare(request_for.call(company_a, 503, later_entry_a))
        ]

        expect(outcomes.map(&:state)).to eq(%w[prepared prepared prepared])
        expected_companies = [company_a.id, company_b.id, company_a.id]
        expect(fake.requests.pluck(:path))
          .to eq(expected_companies.map { |id| "/v1/companies/#{id}/reservations/prepare" })
        # "The default mints a new `Timekeeping::ServiceToken` on each call, for the request's company and the one operation."
        tokens = fake.requests.map { |request| TimekeepingContract::Wire.bearer(request[:headers]) }
        claims = tokens.map { |token| Timekeeping::ServiceToken.verify(token, public_key: timekeeping_key_pair.public_key) }
        expect(claims.map(&:company_id)).to eq(expected_companies)
        expect(claims.map(&:operations)).to all(eq(["reservations.prepare"]))
        # "The client never sends the shared `TIMEKEEPING_SERVICE_TOKEN` and never caches a token."
        expect(tokens).not_to include(shared_token)
        expect(tokens.uniq.size).to eq(3)
        expect(fake.reservations_for(entry_a["id"]).pluck("invoice_id")).to eq([501])
        expect(fake.reservations_for(entry_b["id"]).pluck("invoice_id")).to eq([502])
      end
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

RSpec.describe Timekeeping::ReservationClient, "answers outside the table" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "a 5xx, a transport error, a 404, an unknown status or an unknown state never maps to success" do
    request = Invoices::ReservationRequest.new(
      company_id: 7, invoice_id: 501, operation_id: SecureRandom.uuid, generation: 1,
      disposition: "active", entries: [3]
    )
    answering = lambda do |status, body|
      ->(_method, _path, headers:, body: nil) { TimekeepingContract::Response.new(status:, body: body_for_answer(body)) }
    end
    define_singleton_method(:body_for_answer) { |value| value }

    answers = [
      answering.call(503, { "reason" => "unavailable" }),
      answering.call(404, { "reason" => "not_found" }),
      answering.call(401, { "reason" => "unauthorized" }),
      answering.call(403, { "reason" => "forbidden" }),
      answering.call(418, {}),
      answering.call(200, { "operation_id" => request.operation_id }),
      answering.call(200, { "operation_id" => request.operation_id, "state" => "reserved" }),
      answering.call(200, "not a json object"),
      ->(_method, _path, headers:, body: nil) { raise Timekeeping::ReservationHttp::Error, "prepare failed: Timeout::Error" }
    ]

    # "Nothing outside this table maps to success."
    answers.each do |http|
      outcome = described_class.new(http:).prepare(request)
      expect(outcome.state).to eq("retryable")
    end
  end
end

RSpec.describe Timekeeping::ReservationClient, "delayed copy after a conflict" do
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

  it "a refused replay keeps abort retryable until a delayed copy after the conflict clears is aborted" do
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

  it "mark_billed with an integer billed answer is committed with the billed count, and a non-integer billed is retryable" do
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

    string_count = ->(_method, _path, headers:, body: nil) { TimekeepingContract::Response.new(status: 200, body: { "billed" => "1" }) }
    expect(described_class.new(http: string_count).mark_billed(build.call).state).to eq("retryable")
  end
end

RSpec.describe Timekeeping::ReservationClient, "per-company credentials" do
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:client) { described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)) }

  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem,
                         "TIMEKEEPING_SERVICE_TOKEN" => "shared-service-token") { example.run }
  end

  it "two companies' requests each carry their own path and a freshly minted one-operation token" do
    companies = Array.new(2) { fake.add_company }
    requests = companies.map do |company_id|
      user_id = fake.add_user(company_id:, role: "admin")
      entry_id = fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
      Invoices::ReservationRequest.new(
        company_id:, invoice_id: 501, operation_id: SecureRandom.uuid, generation: fake.generation,
        disposition: "active", entries: [entry_id]
      )
    end

    outcomes = requests.map { |request| client.prepare(request) }
    expect(outcomes.map(&:state)).to eq(%w[prepared prepared])

    # "two companies' requests each carry their own path and token"
    logged = fake.requests
    expect(logged.pluck(:path))
      .to eq(companies.map { |company_id| "/v1/companies/#{company_id}/reservations/prepare" })
    tokens = logged.map { |request| request[:headers]["Authorization"].delete_prefix("Bearer ") }
    expect(tokens).not_to include("shared-service-token")
    claims = tokens.map { |token| Timekeeping::ServiceToken.verify(token, public_key: timekeeping_key_pair.public_key) }
    expect(claims.map(&:company_id)).to eq(companies)
    expect(claims.map(&:operations)).to all(eq(["reservations.prepare"]))

    client.prepare(requests.first)
    expect(fake.requests.last[:headers]["Authorization"]).not_to eq(logged.first[:headers]["Authorization"])
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

RSpec.describe Timekeeping::ReservationClient, "an abort whose replay meets a conflict" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # Acceptance bar: "A prepare that arrives after its abort reserves nothing, including a delayed copy that arrives after a conflict clears"
  it "an abort whose replay is refused stays retryable with reason conflict until a delayed copy is aborted and nothing stays reserved" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:).fetch("id")
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    build = lambda do |invoice_id|
      Invoices::ReservationRequest.new(
        company_id:, invoice_id:, operation_id: SecureRandom.uuid,
        generation: fake.generation, disposition: "active", entries: [entry_id]
      )
    end
    other = build.call(601)
    request = build.call(602)

    # Another invoice holds the entry provisionally, so this abort's replay is refused.
    expect(client.prepare(other).state).to eq("prepared")

    # "A replay refused with 409 conflict stores nothing in the service, so a delayed copy could still reserve later. In that case abort answers retryable with reason `conflict`, and the row is retried until the abort makes the operation terminal."
    refused_abort = client.abort(request)
    expect(refused_abort.state).to eq("retryable")
    expect(refused_abort.reason).to eq("conflict")

    # The conflict clears, then a delayed copy of the original prepare arrives and reserves.
    expect(client.abort(other).state).to eq("aborted")
    expect(client.prepare(request).state).to eq("prepared")
    expect(fake.entry_locked?(entry_id)).to be(true)

    expect(client.abort(request).state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
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

RSpec.describe Timekeeping::ReservationClient, "malformed prepare answers" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "A 401, 403 or 404, an unknown status, or a missing or unknown state maps to retryable."
  # "Nothing outside this table maps to success."
  it "a prepare answer outside the mapping table never maps to success" do
    request = Invoices::ReservationRequest.new(
      company_id: 41, invoice_id: 901, operation_id: SecureRandom.uuid,
      generation: 1, disposition: "active", entries: [7]
    )
    answers = [
      TimekeepingContract::Response.new(status: 200, body: { "operation_id" => request.operation_id, "entries" => [] }),
      TimekeepingContract::Response.new(status: 200, body: { "operation_id" => request.operation_id, "state" => "done" }),
      TimekeepingContract::Response.new(status: 200, body: nil),
      TimekeepingContract::Response.new(status: 418, body: { "state" => "prepared" }),
      TimekeepingContract::Response.new(status: 409, body: { "reason" => "conflict", "conflicts" => [] }),
      TimekeepingContract::Response.new(status: 409, body: { "reason" => "conflict" })
    ]

    states = answers.map do |answer|
      http = Object.new
      http.define_singleton_method(:call) { |_method, _path, headers: {}, body: nil| answer }
      described_class.new(http:).prepare(request).state
    end

    expect(states).to all(eq("retryable"))
  end
end

RSpec.describe Timekeeping::ReservationClient, "malformed mark_billed answers" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "A 200 mark_billed answer with an integer `billed` maps to `committed` with `counts: { billed: }`."
  # "Nothing outside this table maps to success."
  it "a mark_billed answer without an integer billed count is retryable, not committed" do
    request = Invoices::ReservationRequest.new(
      company_id: 42, invoice_id: 902, operation_id: SecureRandom.uuid,
      generation: 1, disposition: "active", entries: [8]
    )
    answers = [
      TimekeepingContract::Response.new(status: 200, body: { "billed" => "3" }),
      TimekeepingContract::Response.new(status: 200, body: {}),
      TimekeepingContract::Response.new(status: 503, body: { "billed" => 3 })
    ]

    states = answers.map do |answer|
      http = Object.new
      http.define_singleton_method(:call) { |_method, _path, headers: {}, body: nil| answer }
      described_class.new(http:).mark_billed(request).state
    end

    expect(states).to all(eq("retryable"))
  end
end
