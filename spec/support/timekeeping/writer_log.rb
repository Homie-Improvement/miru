# frozen_string_literal: true

# The writer log the single-writer guard (docs/architecture/timekeeping-soa.md
# section 12.2) reads to find who changed timesheet_entries rows, and the rules
# it judges those writers by.
module TimekeepingWriterLog
  # The only miru.writer mark each owner state accepts. The strings match the
  # SET LOCAL marks in app/services/timekeeping/gateway.rb and
  # app/services/timekeeping/projection_consumer.rb. A NULL, empty or any other
  # writer is in no list, so it is a violation in every state.
  ALLOWED_WRITERS = {
    "legacy" => ["legacy_gateway"].freeze,
    "timekeeping" => ["projection"].freeze,
    "rollback" => ["projection"].freeze
  }.freeze

  # Every writer section 10.1 names, keyed by its source path, mapped to the
  # guard case that drives it. The invoice reservation boundary replaces code
  # in two files, so both map to one case.
  SECTION_10_1_WRITERS = {
    "app/controllers/api/v1/timesheet_entry_controller.rb" => :web_mobile_controller,
    "app/controllers/api/v1/timesheet_entry/bulk_action_controller.rb" => :bulk_controller,
    "app/controllers/api/v1/cli/timesheet_entries_controller.rb" => :cli_controller,
    "app/controllers/api/v1/agent/timesheet_entries_controller.rb" => :agent_controller,
    "app/services/imports/harvest_time_entries_importer.rb" => :harvest_import,
    "app/models/invoice.rb" => :invoice_reservation,
    "app/models/invoice_line_item.rb" => :invoice_reservation,
    "app/models/agent.rb" => :agent_destroy
  }.freeze

  SECTION_10_1_HEADING = "**Every writer goes through the gateway.**"
  BACKTICKED_TOKEN = /`([^`]+)`/
  # A relative Ruby source path with an optional line number, such as
  # app/models/agent.rb:17. Method names and command names do not match.
  RELATIVE_RUBY_PATH = %r{\A(?!/)([\w./-]+\.rb)(?::\d+)?\z}
  BULLET_START = "- "

  module_function

  # The rows whose writer the state does not allow. The state is checked
  # before the rows, so an unknown state raises even when there are none.
  def violations(state:, rows:)
    allowed = ALLOWED_WRITERS.fetch(state) do
      raise ArgumentError, "unknown Timekeeping owner state #{state.inspect}; " \
                           "expected one of #{ALLOWED_WRITERS.keys.join(', ')}"
    end
    rows.reject { |row| allowed.include?(row.fetch(:writer)) }
  end

  # The source paths in the bullet list that follows the section 10.1 heading,
  # in document order. Raises when the heading is missing, the list is empty,
  # or an item names no path.
  def section_10_1_paths(text)
    section_10_1_items(text).flat_map do |item|
      paths = item.scan(BACKTICKED_TOKEN).flatten.filter_map { |token| token[RELATIVE_RUBY_PATH, 1] }
      raise ArgumentError, "section 10.1 writer item names no source path: #{item.inspect}" if paths.empty?

      paths
    end.uniq
  end

  # Raises naming every path the doc lists that writers lacks, and every path
  # writers holds that the doc does not list.
  def check_section_10_1!(text:, writers: SECTION_10_1_WRITERS)
    doc_paths = section_10_1_paths(text)
    missing_from_writers = doc_paths - writers.keys
    missing_from_doc = writers.keys - doc_paths
    return if missing_from_writers.empty? && missing_from_doc.empty?

    raise ArgumentError, "section 10.1 writer list and SECTION_10_1_WRITERS differ; " \
                         "missing from the writers: #{missing_from_writers.inspect}; " \
                         "missing from the doc: #{missing_from_doc.inspect}"
  end

  # Raises naming every writer case that case_names does not cover.
  def require_cases!(case_names)
    uncovered = SECTION_10_1_WRITERS.values.uniq - case_names.to_a
    return if uncovered.empty?

    raise ArgumentError, "section 10.1 writers with no case: #{uncovered.inspect}"
  end

  # Each bullet item of the list, continuation lines joined. The list starts
  # after the heading line and any blank lines, and ends at the first line that
  # neither starts an item nor continues one, so later paragraphs are not read.
  def section_10_1_items(text)
    lines = text.lines.map(&:chomp)
    heading_index = lines.index { |line| line.include?(SECTION_10_1_HEADING) }
    raise ArgumentError, "no line contains the section 10.1 heading #{SECTION_10_1_HEADING}" unless heading_index

    following = lines.drop(heading_index + 1).drop_while { |line| line.strip.empty? }
    items = following.each_with_object([]) do |line, collected|
      if line.start_with?(BULLET_START)
        collected << line
      elsif collected.any? && line.match?(/\A\s+\S/)
        collected[-1] = "#{collected.last} #{line.strip}"
      else
        break collected
      end
    end
    raise ArgumentError, "the section 10.1 writer list is empty" if items.empty?

    items
  end
  private_class_method :section_10_1_items
end
