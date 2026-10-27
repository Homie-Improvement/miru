# frozen_string_literal: true

FactoryBot.define do
  factory :agent do
    company
    user do
      create(:user, current_workspace: company).tap do |agent_user|
        create(:employment, company:, user: agent_user)
      end
    end
    sequence(:name) { |n| "Delivery Agent #{n}" }
    provider { "custom" }
    active { true }
    metadata { {} }
  end
end
