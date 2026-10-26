# frozen_string_literal: true

# Reads request spec source as text so the meta specs can check that every send_request call in a
# company-scope describe sits in one parameter builder: the one method that calls send_request.
# Other helpers, methods or lambdas, are allowed as long as they call no send_request. Requests
# made with the plain Rails verbs (post, patch) are not tracked; these specs send through
# send_request.
module CompanyScopeRequestSpecScan
  REQUEST_CALL = /\bsend_request\b/
  METHOD_START = /^(?<indent>\s*)def\s+(?<name>\w+[?!]?)/
  # "def ok?(r) = r.first == 200" or "def x; true; end": the whole method sits on its "def" line.
  ONE_LINE_METHOD = /^\s*def\s+\w+[?!]?(?:\([^)]*\))?\s*=(?!=)|\bend\s*$/
  # A "#" that starts a line or follows whitespace, unless it opens "#{...}" string interpolation.
  COMMENT = /(?:^|\s)#(?!\{).*$/
  TOP_LEVEL_DESCRIBE = /^RSpec\.describe\b/

  # The text from the named describe up to the next top-level describe, so helpers in a later
  # block are not counted against this one.
  def company_scope_section(source, describe_name)
    start = source.index("RSpec.describe \"#{describe_name}\"")
    raise ArgumentError, "no describe named #{describe_name}" if start.nil?

    rest = source[start..]
    next_describe = rest.index(TOP_LEVEL_DESCRIBE, 1)
    next_describe ? rest[0...next_describe] : rest
  end

  # Names of the methods that send a request, and how many request calls sit outside them.
  # Comments are removed first: a comment that names send_request sends nothing.
  def params_builder_report(section_source)
    lines = section_source.lines.map { |line| line.sub(COMMENT, "") }
    builder_ranges = method_ranges(lines).select { |_name, range| lines[range].any?(REQUEST_CALL) }
    builder_lines = builder_ranges.values.flat_map(&:to_a)
    stray_lines = lines.each_index.reject { |index| builder_lines.include?(index) }

    {
      builders: builder_ranges.keys,
      stray_requests: stray_lines.sum { |index| lines[index].scan(REQUEST_CALL).size }
    }
  end

  private

    # A method ends on its own line when it is a one-liner, otherwise at the first later "end"
    # with the same indentation as its "def".
    def method_ranges(lines)
      lines.each_with_index.each_with_object({}) do |(line, start), ranges|
        match = line.match(METHOD_START)
        next unless match
        method_end =
          if line.match?(ONE_LINE_METHOD)
            start
          else
            (start + 1...lines.size).find { |index| lines[index].match?(/^#{match[:indent]}end\b/) }
          end
        ranges[match[:name]] = start..(method_end || lines.size - 1)
      end
    end
end

RSpec.configure do |config|
  config.include CompanyScopeRequestSpecScan, file_path: %r{spec/meta/}
end
