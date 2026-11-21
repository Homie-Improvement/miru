# frozen_string_literal: true

# Reads the section 9.3 failure table of docs/architecture/timekeeping-soa.md
# and reports which Integration and Concurrency rows no example names. Contract
# rows are left out because the contract suite in spec/contracts/timekeeping
# already proves them.
#
# The parser is strict on purpose: every shape it does not recognise raises,
# so a moved, copied or malformed table fails the check instead of quietly
# yielding fewer rows to cover.
module TimekeepingSection93Traceability
  HEADING = "### 9.3 Failure cases"
  COLUMNS = ["Case", "State that survives", "How it is detected and repaired", "Proving test"].freeze
  SEPARATOR = /\A\|(\s*:?-+:?\s*\|)+\z/
  # Every Proving test prefix the table may use, and the kind it marks. A row
  # with any other prefix raises, so a mistyped marker cannot drop a row.
  KINDS = { "Integration:" => :integration, "Concurrency:" => :concurrency, "Contract:" => :contract }.freeze
  # The kinds this check covers; Contract rows are proved by the contract suite.
  COVERED_KINDS = %i[integration concurrency].freeze

  Row = Data.define(:case_text, :survives, :proving_test, :kind) do
    # Data freezes only the record, so each string is copied and frozen to keep
    # the caller's later edits out of the row.
    def initialize(case_text:, survives:, proving_test:, kind:)
      raise ArgumentError, "unknown row kind #{kind.inspect}" unless COVERED_KINDS.include?(kind)

      super(case_text: case_text.dup.freeze, survives: survives.dup.freeze,
            proving_test: proving_test.dup.freeze, kind:)
    end
  end

  module_function

  # The covered rows of the section 9.3 table, keyed by their raw Case cell, in
  # table order. Raises ArgumentError when the heading is missing or repeated,
  # when no table follows it, when a row does not have exactly four cells,
  # when a Case repeats, or when a Proving test has no known prefix.
  def rows(markdown)
    table = table_rows(markdown)
    repeated = table.map(&:first).tally.find { |_, count| count > 1 }&.first
    raise ArgumentError, "section 9.3 repeats the Case #{repeated.inspect}" if repeated

    table.filter_map do |case_text, survives, _repair, proving_test|
      kind = row_kind(case_text, proving_test)
      [case_text, Row.new(case_text:, survives:, proving_test:, kind:)] if COVERED_KINDS.include?(kind)
    end.to_h.freeze
  end

  # The Case texts, in table order, that no example name covers. Each name
  # covers only the longest Case it starts with, so a name for "Relay down
  # extra" never covers "Relay down".
  def missing(rows, example_names)
    by_length = rows.keys.sort_by { |case_text| -case_text.length }
    covered = example_names.filter_map { |name| by_length.find { |case_text| name.start_with?(case_text) } }
    (rows.keys - covered).freeze
  end

  # The cells of every body row of the table that starts right after the
  # heading and any blank lines, up to the first line that is not a table row.
  def table_rows(markdown)
    lines = markdown.lines.map(&:strip)
    heading_indexes = lines.each_index.select { |index| lines[index] == HEADING }
    raise ArgumentError, "no line is the section 9.3 heading #{HEADING.inspect}" if heading_indexes.empty?
    raise ArgumentError, "the section 9.3 heading #{HEADING.inspect} appears more than once" if heading_indexes.size > 1

    following = lines.drop(heading_indexes.first + 1).drop_while(&:empty?)
    header, separator, *body = following.take_while { |line| line.start_with?("|") }
    unless header && cells(header) == COLUMNS && separator&.match?(SEPARATOR)
      raise ArgumentError, "no section 9.3 table with the columns #{COLUMNS.join(' | ')} follows the heading"
    end
    raise ArgumentError, "the section 9.3 table has no rows" if body.empty?

    body.map do |line|
      row = cells(line)
      raise ArgumentError, "section 9.3 row does not have #{COLUMNS.size} cells: #{line}" unless row.size == COLUMNS.size

      row
    end
  end

  def cells(line)
    line.delete_prefix("|").delete_suffix("|").split("|", -1).map(&:strip)
  end

  def row_kind(case_text, proving_test)
    kind = KINDS.find { |prefix, _| proving_test.start_with?(prefix) }&.last
    return kind if kind

    raise ArgumentError, "section 9.3 row #{case_text.inspect} has no known Proving test prefix " \
                         "(#{KINDS.keys.join(', ')}): #{proving_test.inspect}"
  end
  private_class_method :table_rows, :cells, :row_kind
end
