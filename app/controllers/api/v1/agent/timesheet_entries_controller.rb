# frozen_string_literal: true

class Api::V1::Agent::TimesheetEntriesController < Api::V1::Agent::BaseController
  def create
    timesheet_entry = entry_gateway.create(user: current_agent.user, project:, attributes: create_attributes)

    render json: {
      notice: I18n.t("timesheet_entry.create.message"),
      entry: timesheet_entry.snippet
    }, status: 200
  end

  private

    def project
      @project ||= ProjectPolicy::Scope.new(current_agent.user, current_company).resolve.find(
        agent_timesheet_entry_params[:project_id].presence || current_agent.default_project_id
      )
    end

    # The gateway writes to whichever store owns the entries. The context
    # carries the authenticated agent, so a forwarded write's token names that
    # agent and its user, and is refused when they do not match.
    def entry_gateway
      Timekeeping::Gateway.new(
        context: Timekeeping::WriteContext.new(
          company: current_company, actor: current_agent.user, actor_kind: "agent",
          request_id: request.request_id, agent: current_agent
        )
      )
    end

    # agent_id comes from the authenticated agent, never from the request, so
    # the entry can only name the agent that wrote it. Naming it also makes the
    # gateway's draft check lock that agent row until the write commits.
    def create_attributes
      {
        duration: agent_timesheet_entry_params[:duration_minutes],
        work_date: agent_timesheet_entry_params[:work_date],
        note: agent_timesheet_entry_params[:note],
        source: "automation",
        source_metadata: agent_timesheet_entry_params[:source_metadata],
        proof_url: agent_timesheet_entry_params[:proof_url],
        proof_metadata: agent_timesheet_entry_params[:proof_metadata],
        external_run_id: agent_timesheet_entry_params[:external_run_id],
        external_session_id: agent_timesheet_entry_params[:external_session_id],
        agent_id: current_agent.id
      }
    end

    def agent_timesheet_entry_params
      params.require(:timesheet_entry).permit(
        :project_id,
        :duration_minutes,
        :work_date,
        :note,
        :proof_url,
        :external_run_id,
        :external_session_id,
        source_metadata: {},
        proof_metadata: {}
      )
    end
end
