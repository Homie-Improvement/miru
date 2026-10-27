# frozen_string_literal: true

class Agent < ApplicationRecord
  PROVIDERS = %w[custom claude codex openclaw].freeze

  belongs_to :company
  belongs_to :user
  belongs_to :default_project, class_name: "Project", optional: true

  # No database key ties entries to agents, so the entries are detached
  # through the Timekeeping gateway before anything else is destroyed. The
  # gateway locks the ownership row and then this agent's row before it
  # detaches, so a concurrent entry save that names this agent either finishes
  # first, and is detached too, or waits and then fails its agent existence
  # check. A refused or failed detach raises, which rolls back this destroy and
  # any user or company destroy that cascades into it, before the keys go.
  before_destroy :detach_timesheet_entries, prepend: true

  has_many :agent_keys, dependent: :destroy
  has_many :timesheet_entries

  validates :name, presence: true, length: { maximum: 80 }, uniqueness: { scope: :company_id, case_sensitive: false }
  validates :provider, presence: true, length: { maximum: 50 }
  validate :default_project_belongs_to_company
  validate :user_belongs_to_company

  scope :active, -> { where(active: true) }

  def provider_label
    provider.to_s.split(/[_-]/).reject(&:blank?).map(&:capitalize).join(" ")
  end

  def backing_user_active_for_company?
    return false if user.blank? || company.blank?
    return false unless user.active_for_authentication?

    user.employed_at?(company_id)
  end

  private

    # A destroy has no web request id, so each attempt gets a fresh one. The
    # gateway derives the detach operation id from it, so a retried destroy
    # is a new command that detaches entries created since the last attempt.
    def detach_timesheet_entries
      context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "agent_destroy",
                                              request_id: SecureRandom.uuid)
      Timekeeping::Gateway.new(context:).detach_agent_entries(agent: self)
    end

    def default_project_belongs_to_company
      return if default_project.blank? || default_project.client.company_id == company_id

      errors.add(:default_project, "must belong to the same company")
    end

    def user_belongs_to_company
      return if user.blank? || company.blank?
      return if user.employed_at?(company_id)

      errors.add(:user, "must belong to the same company")
    end
end
