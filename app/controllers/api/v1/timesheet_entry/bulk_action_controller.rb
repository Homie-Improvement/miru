# frozen_string_literal: true

class Api::V1::TimesheetEntry::BulkActionController < Api::V1::ApplicationController
  skip_after_action :verify_authorized, only: [:update, :destroy]
  after_action :verify_policy_scoped, only: [:update, :destroy]

  # The answer to each refusal, by action. The messages and statuses are the
  # ones these actions answered before they wrote through the gateway.
  REFUSALS = {
    update: {
      no_selection: { key: "timesheet_entry.update.failure", default: "No entries selected", status: :unprocessable_entity },
      not_found: { key: "timesheet_entry.update.failure", default: "No entries found", status: :unprocessable_entity },
      locked: {
        key: "timesheet_entry.update.locked",
        default: "Only admins and owners can edit entries older than %{days} days",
        status: :forbidden
      }
    },
    destroy: {
      not_found: {
        key: "timesheet_entry.destroy.failure", default: "Failed to delete timesheet entries",
        status: :unprocessable_entity
      },
      locked: {
        key: "timesheet_entry.destroy.locked",
        default: "Only admins and owners can delete entries older than %{days} days",
        status: :forbidden
      }
    }
  }.freeze

  def update
    authorize TimesheetEntry, :bulk_update?
    # The gateway looks the entries up in the store that owns them, under the
    # same company and user scope this policy scope applies.
    policy_scope(TimesheetEntry)

    ids = Array(params[:ids]).reject(&:blank?)
    return render_refusal(:update, :no_selection) if ids.empty?

    target_project = ProjectPolicy::Scope.new(current_user, current_company).resolve.find(params[:project_id])
    result = entry_gateway.bulk_move(
      entry_ids: ids, project: target_project, check: method(:update_refusal),
      expected_generation: Timekeeping::Gateway.current_generation, scope: entry_scope
    )
    return render_refusal(:update, result.refusal) unless result.refusal.nil?

    entries = TimesheetEntriesPresenter.new(result.entries).group_snippets_by_work_date
    render json: { notice: I18n.t("timesheet_entry.update.message"), entries: }, status: 200
  end

  def destroy
    authorize TimesheetEntry, :bulk_destroy?
    policy_scope(TimesheetEntry)

    result = entry_gateway.bulk_delete(
      entry_ids: ids_params, check: method(:destroy_refusal),
      expected_generation: Timekeeping::Gateway.current_generation, scope: entry_scope
    )
    return render_refusal(:destroy, result.refusal) unless result.refusal.nil?
    return render_refusal(:destroy, :not_found) unless result.written

    render json: { notice: I18n.t("timesheet_entry.destroy.message") }
  end

  private

    def ids_params
      params.require(:source).require(:ids)
    end

    def entry_gateway
      Timekeeping::Gateway.new(
        context: Timekeeping::WriteContext.new(
          company: current_company, actor: current_user, actor_kind: "user", request_id: request.request_id
        )
      )
    end

    # Admins and owners may target any of the company's entries; everyone
    # else only their own, as TimesheetEntryPolicy::Scope allows.
    def entry_scope
      privileged_user? ? :company : :actor
    end

    def update_refusal(entries)
      return :not_found if entries.empty?

      destroy_refusal(entries)
    end

    def destroy_refusal(entries)
      :locked if entries.any? { |entry| entry_locked?(entry) }
    end

    def render_refusal(action, refusal)
      answer = REFUSALS.fetch(action).fetch(refusal)
      error = I18n.t(answer[:key], days: current_company.timesheet_edit_days, default: answer[:default])
      render json: { error: }, status: answer[:status]
    end

    def privileged_user?
      current_user.has_role?(:admin, current_company) ||
        current_user.has_role?(:owner, current_company)
    end

    def entry_locked?(entry)
      return true if entry.billed?
      return false if privileged_user?

      entry.work_date.present? && entry.work_date < current_company.timesheet_edit_days.days.ago.to_date
    end
end
