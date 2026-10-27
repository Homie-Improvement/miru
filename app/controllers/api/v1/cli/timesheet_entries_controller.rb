# frozen_string_literal: true

class Api::V1::Cli::TimesheetEntriesController < Api::V1::Cli::BaseController
  def create
    authorize TimesheetEntry

    timesheet_entry = entry_gateway.create(user: current_user, project:, attributes: create_attributes)

    render json: {
      notice: I18n.t("timesheet_entry.create.message"),
      entry: timesheet_entry.snippet
    }, status: 200
  end

  def update
    timesheet_entry = entry_gateway.update(
      entry_id: params[:id], project:, attributes: update_attributes, authorize: method(:authorize), scope: :actor
    )

    render json: {
      notice: I18n.t("timesheet_entry.update.message"),
      entry: timesheet_entry.snippet
    }, status: 200
  end

  def destroy
    entry_gateway.destroy(entry_id: params[:id], authorize: method(:authorize), scope: :actor)

    render json: { notice: I18n.t("timesheet_entry.destroy.message") }, status: 200
  end

  private

    def project
      @_project ||= ProjectPolicy::Scope.new(current_user, current_company).resolve.find(cli_timesheet_entry_params[:project_id])
    end

    # The gateway writes to whichever store owns the entries. The CLI, and MCP
    # through it, may only change the signed-in user's own entries, so update
    # and destroy look entries up with the :actor scope.
    def entry_gateway
      Timekeeping::Gateway.new(
        context: Timekeeping::WriteContext.new(
          company: current_company, actor: current_user, actor_kind: "cli", request_id: request.request_id
        )
      )
    end

    def cli_timesheet_entry_params
      params.require(:timesheet_entry).permit(
        :project_id,
        :duration_minutes,
        :work_date,
        :note,
        :bill_status,
        source_metadata: {}
      )
    end

    def create_attributes
      {
        duration: cli_timesheet_entry_params[:duration_minutes],
        work_date: cli_timesheet_entry_params[:work_date],
        note: cli_timesheet_entry_params[:note],
        bill_status: cli_timesheet_entry_params[:bill_status],
        source: "cli",
        source_metadata: cli_timesheet_entry_params[:source_metadata]
      }
    end

    def update_attributes
      attrs = {
        duration: cli_timesheet_entry_params[:duration_minutes],
        work_date: cli_timesheet_entry_params[:work_date],
        source: "cli"
      }
      attrs[:note] = cli_timesheet_entry_params[:note] if cli_timesheet_entry_params.key?(:note)
      attrs[:bill_status] = cli_timesheet_entry_params[:bill_status] if cli_timesheet_entry_params.key?(:bill_status)
      attrs[:source_metadata] = cli_timesheet_entry_params[:source_metadata] if cli_timesheet_entry_params.key?(:source_metadata)
      attrs
    end
end
