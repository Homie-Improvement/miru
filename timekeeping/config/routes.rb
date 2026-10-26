# frozen_string_literal: true

Rails.application.routes.draw do
  scope "v1/companies/:company_id", module: "timekeeping/v1" do
    resources :entries, only: %i[index show create update destroy], param: :entry_id do
      collection do
        post "bulk-move", action: :bulk_move
        post "bulk-delete", action: :bulk_delete
      end
    end

    post "reservations/prepare", to: "reservations#prepare"
    post "reservations/commit", to: "reservations#commit"
    post "reservations/abort", to: "reservations#abort_operation"
    post "invoices/:invoice_id/mark-billed", to: "reservations#mark_billed"
    post "agents/:agent_id/detach-entries", to: "reservations#detach_entries"
  end

  scope "internal/v1", module: "timekeeping/internal/v1" do
    get "metrics", to: "metrics#index"

    # Drawn only when the test hooks are loaded, so elsewhere these paths 404.
    if defined?(Timekeeping::TestHooks)
      post "test-hooks/relay/pause", to: "test_hooks#pause"
      post "test-hooks/relay/resume", to: "test_hooks#resume"
    end
  end
end
