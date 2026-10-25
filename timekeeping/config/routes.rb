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
  end
end
