# frozen_string_literal: true

# The address forwarded specs route to their FakeTimekeeping. Top level so an
# example body can read it as well as the helpers below.
FORWARDED_TIMEKEEPING_BASE_URL = "http://timekeeping.test"

# Setup for specs whose entry writes are forwarded to a FakeTimekeeping instead
# of the legacy store. Local employments and roles stay with each spec, because
# they differ from one group to the next.
module TimekeepingForwardingHelpers
  # Hands ownership to Timekeeping at generation 2 on both the ownership row and
  # the fake, registers the company, each user with its role and the project on
  # the fake, and routes HTTP for base_url to it. users maps a user to its role.
  def arrange_forwarded_timekeeping(fake, company:, users:, project:, base_url: FORWARDED_TIMEKEEPING_BASE_URL)
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
    fake.generation = 2
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    users.each { |user, role| fake.register_user(id: user.id, company_id: company.id, role:) }
    fake.register_project(id: project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
  end

  # Sets the Timekeeping base URL and the user token signing key for the block,
  # so the importer forwards its writes, and puts both back afterwards.
  def with_forwarded_timekeeping_env(base_url = FORWARDED_TIMEKEEPING_BASE_URL, &block)
    with_timekeeping_env(
      {
        Timekeeping::EntryApiClient::BASE_URL_ENV => base_url,
        Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem
      },
      &block
    )
  end
end

RSpec.configure do |config|
  config.include TimekeepingForwardingHelpers
end
