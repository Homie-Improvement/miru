# frozen_string_literal: true

# The base of the ownership handoff routes (docs/architecture/timekeeping-soa.md
# section 10.5). A refusal answers with its reason only: an exception message
# can quote stored rows, such as a Postgres "Failing row contains" detail, and
# these routes carry every company's data.
class Timekeeping::Internal::V1::Handoff::BaseController < Timekeeping::Internal::V1::ServiceController
  rescue_from Timekeeping::Handoff::Store::Error, with: :render_handoff_refused
  rescue_from Timekeeping::Handoff::Checkpoint::ShapeError, JSON::ParserError,
              ActionDispatch::Http::Parameters::ParseError, with: :render_invalid_request

  private

    # The request body as plain JSON values. The services take plain Hashes,
    # not ActionController::Parameters, and tell an Integer from a string, so
    # the body is read exactly as sent.
    def json_body
      body = request.raw_post.presence || "{}"
      document = JSON.parse(body)
      raise Timekeeping::Handoff::Checkpoint::ShapeError, "the request body is not a JSON object" unless document.is_a?(Hash)

      document
    end

    def service_store
      Timekeeping::Handoff::ServiceStore.new(connection: ApplicationRecord.connection)
    end

    def render_handoff_refused
      render_reason(:handoff_refused)
    end

    def render_invalid_request
      render_reason(:invalid_request)
    end
end
