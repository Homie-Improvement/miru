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
    # The project is resolved only for a write, so a retry of a committed
    # update replays even after the project was archived.
    timesheet_entry = entry_gateway.update(
      entry_id: params[:id], requested_project_id: cli_timesheet_entry_params[:project_id],
      attributes: update_attributes, authorize: method(:authorize),
      authorize_replay: method(:authorize_replayed_entry), scope: :actor
    ) { project }

    render json: {
      notice: I18n.t("timesheet_entry.update.message"),
      entry: timesheet_entry.snippet
    }, status: 200
  end

  def destroy
    entry_gateway.destroy(entry_id: params[:id], authorize: method(:authorize),
                          authorize_replay: method(:authorize_replayed_entry), scope: :actor)

    render json: { notice: I18n.t("timesheet_entry.destroy.message") }, status: 200
  end

  private

    # A replayed update, or a delete replayed by the legacy store, returns a
    # write already committed, so reading it back needs only show?: the edit
    # policy may refuse the entry by now, such as one the edit billed or one
    # past its edit window. The gateway's prepared and Timekeeping delete
    # replays still check the delete policy instead.
    def authorize_replayed_entry(entry)
      authorize(entry, :show?)
    end

    def project
      @_project ||= ProjectPolicy::Scope.new(current_user, current_company).resolve.find(cli_timesheet_entry_params[:project_id])
    end

    # The gateway writes to whichever store owns the entries. The CLI, and MCP
    # through it, may only change the signed-in user's own entries, so update
    # and destroy look entries up with the :actor scope.
    def entry_gateway
      Timekeeping::Gateway.new(
        context: Timekeeping::WriteContext.for_request(
          request, company: current_company, actor: current_user, actor_kind: "cli"
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
