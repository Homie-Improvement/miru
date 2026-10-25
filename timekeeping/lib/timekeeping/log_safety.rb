# frozen_string_literal: true

require "cgi"
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
    QUERY_SEPARATOR = /\A[&;]\z/
    QUERY_PARAM_NAME = /\A[^\[\]]+(?:\[[^\[\]]*\])*\z/

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
    # correlation, unless it is the configured service token, which may itself
    # be a UUID. Any other value could be a credential; its digest still lets
    # the same id be matched across lines.
    def request_id_tag(request_id, service_token: nil)
      id = request_id.to_s
      return id if UUID.match?(id) && !Identity.service_token?(id, service_token)

      "sha256:#{Digest::SHA256.hexdigest(id)[0, REQUEST_ID_DIGEST_LENGTH]}"
    end

    # The HTTP method is caller-controlled text too; only a known method name
    # is logged.
    def loggable_method(method)
      ActionDispatch::Request::HTTP_METHODS.include?(method) ? method : MASK
    end

    # The query string for the request start line. Rails masks only values
    # there, so a credential sent as a parameter name would survive: a part
    # whose name is not on the allow-list is masked whole, and an allowed name
    # keeps its value only when the value has that name's shape.
    def loggable_query(query_string)
      query_string.to_s.split(/([&;])/).map do |part|
        QUERY_SEPARATOR.match?(part) ? part : loggable_query_part(part)
      end.join
    end

    def loggable_query_part(part)
      raw_name, raw_value = part.split("=", 2)
      name = CGI.unescape(raw_name.to_s)
      return MASK unless clear_param_name?(name)
      return part if raw_value.nil? || clear_param?(base_param_name(name), CGI.unescape(raw_value))

      "#{raw_name}=#{MASK}"
    end

    # Parameters as the controller's "Parameters:" log line shows them, after
    # the parameter filter has masked their values. A name outside the
    # allow-list, at any depth, is masked as well.
    def loggable_params(params)
      params.each_with_object({}) do |(name, value), loggable|
        if CLEAR_PARAM_SHAPES.key?(name.to_s)
          loggable[name] = loggable_param_value(value)
        else
          loggable[MASK] = MASK
        end
      end
    end

    def loggable_param_value(value)
      case value
      when Hash then loggable_params(value)
      when Array then value.map { |element| loggable_param_value(element) }
      else value
      end
    end

    # "entry_ids[]" and "project_id" are allowed; a name with any bracketed
    # part outside the allow-list, or of another form, is not.
    def clear_param_name?(name)
      return false unless QUERY_PARAM_NAME.match?(name)

      [base_param_name(name), *name.scan(/\[([^\[\]]*)\]/).flatten.reject(&:empty?)]
        .all? { |part| CLEAR_PARAM_SHAPES.key?(part) }
    end

    def base_param_name(name)
      name[/\A[^\[]*/]
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
