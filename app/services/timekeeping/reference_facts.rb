# frozen_string_literal: true

module Timekeeping
  # Reads the facts the Timekeeping service decides writes on: the company's
  # edit window, its users' roles, and billable and membership facts for the
  # requested projects. Every query starts from the company, so a project or
  # user of another company can never appear. A requested project the company
  # does not own is reported in missing_project_ids exactly like an id that
  # does not exist, so the result never reveals another company's records.
  class ReferenceFacts
    # User#primary_role gives this role to a user with no role in the company.
    DEFAULT_ROLE = "employee"

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
        users: user_ids.map { |id| { id:, role: roles_by_user_id.fetch(id, DEFAULT_ROLE) } },
        projects: projects.map { |project| project_facts(project) },
        missing_project_ids: requested_project_ids - projects.map(&:id)
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

      def projects
        @projects ||= company.projects.kept.where(id: requested_project_ids).order(:id).to_a
      end

      def user_ids
        @user_ids ||= User.kept
          .where(id: company.employments.kept.select(:user_id))
          .order(:id)
          .pluck(:id)
      end

      # Matches User#primary_role: the role with the lowest id wins.
      def roles_by_user_id
        @roles_by_user_id ||= Role.where(resource: company)
          .joins(:users)
          .where(users: { id: user_ids })
          .order("roles.id")
          .pluck("users.id", "roles.name")
          .each_with_object({}) { |(user_id, name), roles| roles[user_id] ||= name }
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
