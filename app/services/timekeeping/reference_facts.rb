# frozen_string_literal: true

module Timekeeping
  # Reads the facts the Timekeeping service decides writes on: the company's
  # edit window, its users' roles, billable and membership facts for the
  # requested projects, and its agents with their users. Every query starts
  # from the company, so a project, user or agent of another company can never
  # appear. A requested project the company
  # does not own is reported in missing_project_ids exactly like an id that
  # does not exist, so the result never reveals another company's records.
  class ReferenceFacts
    # The roles that act for colleagues, as the entry API contract names them.
    PRIVILEGED_ROLES = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_api.yml"))
      .fetch("privileged_roles").freeze

    def self.call(company:, project_ids:)
      new(company:, project_ids:).call
    end

    def initialize(company:, project_ids:)
      @company = company
      @requested_project_ids = Array(project_ids).map(&:to_i).uniq
    end

    def call
      {
        company_id: company.id,
        edit_days: company.timesheet_edit_days,
        users: user_ids.map { |id| { id:, role: role_from(held_role_names_by_user_id.fetch(id, [])) } },
        projects: projects.map { |project| project_facts(project) },
        missing_project_ids: requested_project_ids - projects.map(&:id),
        agents: agents
      }
    end

    private

      attr_reader :company, :requested_project_ids

      def project_facts(project)
        {
          id: project.id,
          company_id: company.id,
          billable: project.billable,
          member_user_ids: member_user_ids_by_project_id.fetch(project.id, [])
        }
      end

      # Every agent of the company, active or not: design rule S7 and the
      # projection ignore active, so an inactive agent still owns its entries.
      # Only id and user_id leave the monolith.
      #
      # An agent whose destroy holds its row lock (Gateway#detach_agent_entries
      # takes it before Timekeeping detaches its entries) is left out without
      # waiting, so facts never list an agent while its deletion may still
      # commit. Timekeeping relies on this to tell a detach whose deletion
      # rolled back from one that facts read earlier have not seen. KEY SHARE
      # does not conflict with ordinary agent updates or entry saves.
      def agents
        company.agents.order(:id).lock("FOR KEY SHARE SKIP LOCKED").pluck(:id, :user_id)
          .map { |id, user_id| { id:, user_id: } }
      end

      def projects
        @projects ||= company.projects.kept.where(id: requested_project_ids).order(:id).to_a
      end

      def user_ids
        @user_ids ||= User.kept
          .where(id: company.employments.kept.select(:user_id))
          .order(:id)
          .pluck(:id)
      end

      # The oldest owner or admin role the user holds in the company, matching
      # the monolith's has_role?(:owner | :admin, company) checks that let a
      # user act for colleagues; otherwise their oldest role there, as
      # User.primary_roles_for picks it.
      def role_from(held_role_names)
        held_role_names.find { |name| PRIVILEGED_ROLES.include?(name) } || held_role_names.first || User::DEFAULT_ROLE
      end

      # Each listed user's role names, oldest first. Only roles whose resource
      # is exactly this company count, so a role held in another company or a
      # global role never reaches a user's role here.
      def held_role_names_by_user_id
        @held_role_names_by_user_id ||= Role.where(resource: company)
          .joins(:users)
          .where(users: { id: user_ids })
          .order("roles.id")
          .pluck("users.id", "roles.name")
          .group_by(&:first)
          .transform_values { |pairs| pairs.map(&:last) }
      end

      def member_user_ids_by_project_id
        @member_user_ids_by_project_id ||= ProjectMember.kept
          .where(project_id: projects.map(&:id), user_id: user_ids)
          .order(:user_id)
          .distinct
          .pluck(:project_id, :user_id)
          .group_by(&:first)
          .transform_values { |pairs| pairs.map(&:last) }
      end
  end
end
