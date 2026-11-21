# frozen_string_literal: true

# The reference facts Timekeeping reads before a background write
# (docs/architecture/timekeeping-soa.md section 3.4). The response shape is
# contracts/timekeeping/reference.yml.
class Internal::V1::Companies::ReferencesController < Internal::V1::BaseController
  MAX_PROJECT_IDS = 200
  MAX_AGENT_IDS = 200
  INTEGER_ID = /\A\d+\z/

  def show
    company = Company.find_by(id: params[:company_id].to_s[INTEGER_ID])
    return render_reason(:not_found) unless company

    project_ids = requested_ids(params[:project_ids], limit: MAX_PROJECT_IDS)
    return render_reason(:invalid_project_ids, status: 422) unless project_ids

    agent_ids = requested_ids(params[:agent_ids], limit: MAX_AGENT_IDS)
    return render_reason(:invalid_agent_ids, status: 422) unless agent_ids

    response.headers["Cache-Control"] = "no-store"
    render json: Timekeeping::ReferenceFacts.call(company:, project_ids:, agent_ids:)
  end

  private

    # A comma-separated list or an array of ids. Returns nil when the list is
    # malformed or longer than limit.
    def requested_ids(raw, limit:)
      ids = raw.is_a?(Array) ? raw : raw.to_s.split(",")
      ids = ids.map { |id| id.to_s.strip }
      return nil if ids.size > limit || ids.any? { |id| !id.match?(INTEGER_ID) }

      ids.map(&:to_i)
    end
end
