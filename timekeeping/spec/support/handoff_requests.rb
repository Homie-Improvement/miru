# frozen_string_literal: true

# Requests to the internal handoff routes, so a path, a header or the service
# credential setup is written once rather than in every handoff spec.
module HandoffRequests
  # Every handoff route, with the smallest body that reaches its controller.
  # Specs that prove every route refuses a caller read this table, so a new
  # handoff route is added here and every such spec covers it.
  HANDOFF_ROUTES = {
    checkpoint_export: [:get, "/internal/v1/handoff/checkpoint", nil],
    checkpoint_load: [:put, "/internal/v1/handoff/checkpoint", {}],
    entry_id_sequence: [:post, "/internal/v1/handoff/entry_id_sequence", { above: 500 }],
    outbox_position: [:get, "/internal/v1/handoff/outbox_position", nil],
    correction_snapshots: [:put, "/internal/v1/handoff/correction_snapshots", { generation: 2, version: 1, snapshots: [] }],
    admission_fence: [:post, "/internal/v1/handoff/admission/fence", nil],
    admission_admit: [:post, "/internal/v1/handoff/admission/admit", { generation: 7 }]
  }.transform_values(&:freeze).freeze

  # A fresh service token per example, so no spec depends on another's value.
  def handoff_service_token
    @handoff_service_token ||= "service-#{SecureRandom.hex(24)}"
  end

  # Sets TIMEKEEPING_SERVICE_TOKEN for the block. The caller must say whether
  # TOKEN_PUBLIC_KEY is set too: user tokens can only be verified with it, and
  # some specs prove a refusal without it, so neither choice is a safe default.
  def with_handoff_env(public_key:, service_token: handoff_service_token, &)
    values = { Timekeeping::Environment::SERVICE_TOKEN => service_token }
    values[Timekeeping::Environment::TOKEN_PUBLIC_KEY] = rsa_key_pair.public_key.to_pem if public_key
    with_timekeeping_env(values, &)
  end

  # Sends the named route with a JSON body. A Hash body is generated as JSON; a
  # String is sent as written, so a spec can send a tampered or unparseable
  # body. Pass body: to replace the route's default body. A nil authorization
  # sends no Authorization header; by default the service bearer is sent.
  def handoff_request(route, body: HANDOFF_ROUTES.fetch(route)[2], authorization: "Bearer #{handoff_service_token}")
    verb, path, = HANDOFF_ROUTES.fetch(route)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = authorization if authorization
    params = body.is_a?(String) || body.nil? ? body : JSON.generate(body)
    public_send(verb, path, params:, headers:)
    response
  end
end

RSpec.configure do |config|
  config.include HandoffRequests, type: :request
end
