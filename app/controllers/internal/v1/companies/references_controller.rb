# frozen_string_literal: true

# The reference facts Timekeeping reads before a background write
# (docs/architecture/timekeeping-soa.md section 3.4). The response shape is
# contracts/timekeeping/reference.yml.
class Internal::V1::Companies::ReferencesController < Internal::V1::BaseController
  MAX_PROJECT_IDS = 200
  INTEGER_ID = /\A\d+\z/

  def show
    company = Company.find_by(id: params[:company_id].to_s[INTEGER_ID])
    return render_reason(:not_found) unless company

    project_ids = requested_project_ids
    return render_reason(:invalid_project_ids, status: 422) unless project_ids

    response.headers["Cache-Control"] = "no-store"
    render json: Timekeeping::ReferenceFacts.call(company:, project_ids:)
  end

  private

    # Returns nil when the list is malformed or too long.
    def requested_project_ids
      raw = params[:project_ids]
      ids = raw.is_a?(Array) ? raw : raw.to_s.split(",")
      ids = ids.map { |id| id.to_s.strip }
      return nil if ids.size > MAX_PROJECT_IDS || ids.any? { |id| !id.match?(INTEGER_ID) }

      ids.map(&:to_i)
    end
end
