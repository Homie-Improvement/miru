# frozen_string_literal: true

require "digest"

module Timekeeping
  # Decides which request values may appear in a log line. A caller can send a
  # bearer token or the service token under any parameter name or as the
  # X-Request-Id header, so a value is shown in clear only when both its name
  # and its shape say it cannot be a credential.
  module LogSafety
    MASK = "[FILTERED]"

    ID = /\A[0-9]{1,19}\z/
    DATE = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    REQUEST_ID_DIGEST_LENGTH = 16

    # The fixed words of the service's routes. Any other path segment is a
    # caller's value, such as a company or entry id, and could be a credential.
    PATH_WORDS = %w[v1 companies entries].freeze

    # The only parameters logged in clear, each with the one value shape it may
    # have. For entry_ids the shape applies to each element.
    CLEAR_PARAM_SHAPES = {
      "company_id" => ID,
      "entry_id" => ID,
      "entry_ids" => ID,
      "project_id" => ID,
      "user_id" => ID,
      "work_date" => DATE,
      "from" => DATE,
      "to" => DATE
    }.freeze

    # Matches every parameter name outside CLEAR_PARAM_SHAPES, so its whole
    # value is masked, nested hashes such as source_metadata included.
    MASKED_PARAM_NAMES = /\A(?!(?:#{CLEAR_PARAM_SHAPES.keys.map { |name| Regexp.escape(name) }.join("|")})\z)/

    module_function

    def clear_param?(key, value)
      shape = CLEAR_PARAM_SHAPES[key.to_s]
      shape.present? && shape.match?(value.to_s)
    end

    # A UUID is the form Rails generates and sends, so it is kept for
    # correlation. Any other value could be a credential; its digest still
    # lets the same id be matched across lines.
    def request_id_tag(request_id)
      id = request_id.to_s
      return id if UUID.match?(id)

      "sha256:#{Digest::SHA256.hexdigest(id)[0, REQUEST_ID_DIGEST_LENGTH]}"
    end

    # Rails filters only the query string of the path it logs. This masks each
    # path segment that is neither a route word nor a plain id or date, so a
    # token sent in place of a company or entry id is never logged.
    def loggable_path(path)
      path.to_s.split("/", -1).map { |segment| clear_path_segment?(segment) ? segment : MASK }.join("/")
    end

    def clear_path_segment?(segment)
      segment.empty? || PATH_WORDS.include?(segment) || ID.match?(segment) || DATE.match?(segment)
    end

    # ActiveSupport::ParameterFilter passes a copy of each value under an
    # allowed name to this block and logs whatever the copy holds afterwards.
    MASK_UNCLEAR_VALUE = lambda do |key, value|
      value.replace(MASK) if value.is_a?(String) && !LogSafety.clear_param?(key, value)
    end

    # Name filter first: a masked name never reaches the value check.
    PARAMETER_FILTERS = [MASKED_PARAM_NAMES, MASK_UNCLEAR_VALUE].freeze
  end
end
