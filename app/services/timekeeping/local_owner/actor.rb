# frozen_string_literal: true

module Timekeeping
  class LocalOwner
    # Who a local write acts for: a signed-in user, as the gateway passes it,
    # or a background service. It comes only from LocalOwner.call's keyword,
    # never from the request body. A user's role is carried as the gateway
    # sends it, but access is decided on the role Timekeeping::ReferenceFacts
    # reads for the company, so a stale or foreign role grants nothing.
    Actor = Data.define(:kind, :user_id, :role, :name, :company_id, :operations) do
      def self.user(user_id:, role:)
        new(kind: :user, user_id:, role:, name: nil, company_id: nil, operations: [].freeze)
      end

      def self.service(name:, company_id:, operations:)
        new(kind: :service, user_id: nil, role: nil, name:, company_id:, operations: Array(operations).map(&:to_s).freeze)
      end

      def user?
        kind == :user
      end
    end
  end
end
