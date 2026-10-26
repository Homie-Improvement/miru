# frozen_string_literal: true

Rails.application.routes.draw do
  scope "v1/companies/:company_id", module: "timekeeping/v1" do
    resources :entries, only: %i[index show create update destroy], param: :entry_id do
      collection do
        post "bulk-move", action: :bulk_move
        post "bulk-delete", action: :bulk_delete
      end
    end
  end

  scope "internal/v1", module: "timekeeping/internal/v1" do
    get "metrics", to: "metrics#index"

    scope "handoff", module: "handoff" do
      get "checkpoint", to: "checkpoints#show"
      put "checkpoint", to: "checkpoints#update"
      post "entry_id_sequence", to: "entry_id_sequences#create"
      get "outbox_position", to: "outbox_positions#show"
      put "correction_snapshots", to: "correction_snapshots#update"
      post "admission/fence", to: "admissions#fence"
      post "admission/admit", to: "admissions#admit"
    end

    # Drawn only when the test hooks are loaded, so elsewhere these paths 404.
    if defined?(Timekeeping::TestHooks)
      post "test-hooks/relay/pause", to: "test_hooks#pause"
      post "test-hooks/relay/resume", to: "test_hooks#resume"
    end
  end
end
