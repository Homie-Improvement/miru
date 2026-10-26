# frozen_string_literal: true

class Api::V1::TimesheetEntryController < Api::V1::ApplicationController
  include DateRangeParamParsing

  skip_after_action :verify_authorized, only: [:index]
  after_action :verify_policy_scoped, only: [:index]

  def index
    policy_scope(TimesheetEntry)
    user = current_company.users.find(selected_user_id)
    data = TimeTrackingIndexService.new(
      current_user: current_user,
      user: user,
      company: current_company,
      from: parsed_date_param(:from) || 1.month.ago.beginning_of_month,
      to: parsed_date_param(:to) || 1.month.since.end_of_month,
      year: params[:year] || Date.today.year
    ).entries_payload

    render :index, locals: {
      entries: data[:entries],
      holiday_infos: data[:holiday_infos],
      leave_types: data[:leave_types],
      company: current_company
    }, status: 200
  end

  def create
    authorize TimesheetEntry
    timesheet_entry = entry_gateway.create(
      user: timesheet_entry_user, project: current_project, attributes: timesheet_entry_params.to_h
    )
    render json: { notice: I18n.t("timesheet_entry.create.message"), entry: timesheet_entry.snippet }
  end

  def update
    timesheet_entry = entry_gateway.update(
      entry_id: params[:id], project: current_project, attributes: timesheet_entry_params.to_h,
      authorize: method(:authorize)
    )
    render json: { notice: I18n.t("timesheet_entry.update.message"), entry: timesheet_entry.snippet }, status: 200
  end

  def destroy
    entry_gateway.destroy(entry_id: params[:id], authorize: method(:authorize))
    render json: { notice: I18n.t("timesheet_entry.destroy.message") }
  end

  private

    def selected_user_id
      return current_user.id unless current_user.has_role?(:owner, current_company) || current_user.has_role?(:admin, current_company)

      params[:user_id] || current_user.id
    end

    def current_project
      @_current_project ||= current_company.projects.kept.find(params[:project_id])
    end

    # The gateway writes to whichever store owns the entries; the controller
    # only resolves the target user and project inside the current company.
    def entry_gateway
      Timekeeping::Gateway.new(
        context: Timekeeping::WriteContext.new(
          company: current_company, actor: current_user, actor_kind: "user", request_id: request.request_id
        )
      )
    end

    def timesheet_entry_user
      if current_user.has_role?(:owner, current_company) || current_user.has_role?(:admin, current_company)
        return current_company.users.find(params[:user_id] || current_user.id)
      end

      return current_user if params[:user_id].blank? || params[:user_id].to_i == current_user.id

      raise Pundit::NotAuthorizedError
    end

    def timesheet_entry_params
      params.require(:timesheet_entry).permit(:project_id, :duration, :work_date, :note, :bill_status)
    end
end
