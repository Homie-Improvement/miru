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
    # The request's user_id goes to the gateway unchanged. The prepared store's
    # local owner decides it itself; the other stores write for the user
    # timesheet_entry_user resolves.
    timesheet_entry = entry_gateway.create(
      requested_user_id: params[:user_id], project: current_project, attributes: timesheet_entry_params.to_h
    ) { timesheet_entry_user }
    render json: { notice: I18n.t("timesheet_entry.create.message"), entry: timesheet_entry.snippet }
  end

  def update
    # The project is resolved only for a write, so a retry of a committed
    # update replays even after the project was archived.
    timesheet_entry = entry_gateway.update(
      entry_id: params[:id], requested_project_id: params[:project_id], attributes: timesheet_entry_params.to_h,
      authorize: method(:authorize), authorize_replay: method(:authorize_replayed_entry)
    ) { current_project }
    render json: { notice: I18n.t("timesheet_entry.update.message"), entry: timesheet_entry.snippet }, status: 200
  end

  def destroy
    entry_gateway.destroy(entry_id: params[:id], authorize: method(:authorize),
                          authorize_replay: method(:authorize_replayed_entry))
    render json: { notice: I18n.t("timesheet_entry.destroy.message") }
  end

  private

    # A replayed update, or a delete replayed from a legacy-store receipt
    # (before or after a handoff), returns a write already committed, so
    # reading it back needs only show?: the edit policy may refuse the entry
    # by now, such as one the edit billed or one past its edit window. The
    # gateway's prepared and Timekeeping delete replays still check the
    # delete policy instead.
    def authorize_replayed_entry(entry)
      authorize(entry, :show?)
    end

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
        context: Timekeeping::WriteContext.for_request(
          request, company: current_company, actor: current_user, actor_kind: "user"
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

    # The entry's project comes only from the top-level project_id, which
    # current_project resolves inside the current company. A project_id in
    # these attributes would be assigned over it unchecked.
    def timesheet_entry_params
      params.require(:timesheet_entry).permit(:duration, :work_date, :note, :bill_status)
    end
end
