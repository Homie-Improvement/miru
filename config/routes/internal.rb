# frozen_string_literal: true

# Service-to-service endpoints for the Timekeeping service. They accept only
# the Timekeeping service token, never a user session.
namespace :internal, defaults: { format: "json" } do
  namespace :v1 do
    resources :companies, only: [] do
      resource :reference, only: :show, controller: "companies/references"
    end
  end
end
