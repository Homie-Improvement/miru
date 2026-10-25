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
end
