# frozen_string_literal: true

# The address forwarded specs route to their FakeTimekeeping. Top level so an
# example body can read it as well as the helpers below.
FORWARDED_TIMEKEEPING_BASE_URL = "http://timekeeping.test"

# Setup for specs whose entry writes are forwarded to a FakeTimekeeping instead
# of the legacy store. Local employments and roles stay with each spec, because
# they differ from one group to the next.
module TimekeepingForwardingHelpers
  # Puts the ownership row and the fake in owner_state, registers the company,
  # each user with its role and the project on the fake, and routes HTTP for
  # base_url to it. users maps a user to its role. With no owner_state, it
  # hands ownership to Timekeeping at generation 2 on both sides; with one, as
  # in a regression run, the row keeps that state so the run proves the state
  # it selected.
  #
  # While TimekeepingRegressionAdapter runs, the live app owns the connection:
  # nothing is registered on the fake and no HTTP is routed to it, so a spec
  # cannot pass while its requests silently reach the fake.
  def arrange_forwarded_timekeeping(fake, company:, users:, project:, base_url: FORWARDED_TIMEKEEPING_BASE_URL,
                                    owner_state: TimekeepingOwnerState::SELECTED)
    if owner_state
      TimekeepingOwnerState.apply!(owner_state)
      fake.generation = TimekeepingOwnerState.fetch(owner_state).fetch(:generation)
    else
      TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
      fake.generation = 2
    end
    return if TimekeepingRegressionAdapter.current

    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    users.each { |user, role| fake.register_user(id: user.id, company_id: company.id, role:) }
    fake.register_project(id: project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
  end

  # The Idempotency-Key header of a request the fake recorded, matched without
  # regard to case because the HTTP client may send the name in any case.
  def forwarded_idempotency_key(request)
    request.fetch(:headers).find { |key, _value| key.to_s.casecmp?("Idempotency-Key") }&.last
  end

  # Sets the Timekeeping base URL and the user token signing key for the block,
  # so the importer forwards its writes, and puts both back afterwards. While
  # TimekeepingRegressionAdapter runs, its URL and key are used instead, even
  # over an explicit base_url, because the live app alone owns the connection.
  def with_forwarded_timekeeping_env(base_url = FORWARDED_TIMEKEEPING_BASE_URL, &block)
    live = TimekeepingRegressionAdapter.current
    with_timekeeping_env(
      {
        Timekeeping::EntryApiClient::BASE_URL_ENV => live ? live.base_url : base_url,
        Timekeeping::UserToken::PRIVATE_KEY_ENV => (live ? live.private_key : timekeeping_key_pair).to_pem
      },
      &block
    )
  end
end

RSpec.configure do |config|
  config.include TimekeepingForwardingHelpers
end
