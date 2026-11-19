# frozen_string_literal: true

require "prism"
require "set"

# Reads the source of the Timekeeping integration specs and reports examples
# that would run without the committed_data tag, or that load the handoff
# fakes. Those specs prove behaviour across real connections and processes, so
# each one must commit its rows and must use the real stores, not the fakes.
#
# The check parses source instead of loading the specs: spec/rails_helper.rb
# loads every support file, so $LOADED_FEATURES cannot tell which spec loads
# the fakes, and loading the integration specs here would register their
# examples in the meta run.
module TimekeepingIntegrationTags
  Violation = Data.define(:path, :line, :kind, :detail)

  HANDOFF_FAKES_PATH = File.expand_path("handoff_fakes.rb", __dir__)
  TAG = :committed_data

  # RSpec core's group and example methods, aliases included, so an example
  # written with fit or xit is checked like one written with it.
  GROUP_METHODS = %i[describe context example_group fdescribe xdescribe fcontext xcontext].freeze
  EXAMPLE_METHODS = %i[it specify example focus pending skip fit fspecify fexample xit xspecify xexample].freeze
  LOAD_METHODS = %i[require require_relative load].freeze
  HANDOFF_FAKES_BASENAME = "handoff_fakes"
  # Object::Name and ::Name both name the top-level constant Name.
  TOP_LEVEL_NAMESPACE = :Object

  module_function

  # Every violation in one spec file's source, in source order.
  def violations(path, source, fake_constants: handoff_fake_constants)
    found = []
    walk(Prism.parse(source).value, false, fake_constants) do |node, kind, detail|
      found << Violation.new(path:, line: node.location.start_line, kind:, detail:)
    end
    found.sort_by(&:line).freeze
  end

  # The fully qualified name of every class and module the fakes file
  # declares. Raises ArgumentError when there are none, so a renamed or
  # emptied fakes file fails the check instead of matching nothing.
  def handoff_fake_constants(source = File.read(HANDOFF_FAKES_PATH))
    names = declared_constants(Prism.parse(source).value, nil).to_set.freeze
    raise ArgumentError, "the handoff fakes source declares no class or module" if names.empty?

    names
  end

  # tagged is whether the nearest committed_data setting above node is true.
  def walk(node, tagged, fake_constants, &report)
    case node
    when Prism::CallNode
      walk_call(node, tagged, fake_constants, &report)
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      # A path is checked whole; its parent segments are not separate references.
      if fake_reference?(node, fake_constants)
        report.call(node, :loads_handoff_fakes, "references #{node.slice}")
      end
    else
      node.compact_child_nodes.each { |child| walk(child, tagged, fake_constants, &report) }
    end
  end

  def walk_call(node, tagged, fake_constants, &report)
    report.call(node, :loads_handoff_fakes, node.slice) if loads_handoff_fakes?(node)

    example = example_call?(node)
    tagged = tag_setting(node).fetch(:value, tagged) if example || group_call?(node)
    report.call(node, :missing_committed_data, "example lacks committed_data: true") if example && !tagged
    node.compact_child_nodes.each { |child| walk(child, tagged, fake_constants, &report) }
  end

  def group_call?(node)
    GROUP_METHODS.include?(node.name) && (node.receiver.nil? || rspec_receiver?(node.receiver))
  end

  # An example call has a description or a block; a bare `example` with
  # neither is a method call, not an example.
  def example_call?(node)
    EXAMPLE_METHODS.include?(node.name) && node.receiver.nil? && (node.arguments || node.block)
  end

  def rspec_receiver?(receiver)
    receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :RSpec
  end

  # { value: true | false } when the call sets the tag, {} when it does not.
  # A bare :committed_data symbol means true, as it does to RSpec; any value
  # other than the literal true, false and nil included, counts as untagged.
  def tag_setting(node)
    (node.arguments&.arguments || []).each_with_object({}) do |argument, setting|
      case argument
      when Prism::SymbolNode
        setting[:value] = true if argument.unescaped.to_sym == TAG
      when Prism::KeywordHashNode, Prism::HashNode
        argument.elements.each do |element|
          next unless element.is_a?(Prism::AssocNode) && tag_key?(element.key)

          setting[:value] = element.value.is_a?(Prism::TrueNode)
        end
      end
    end
  end

  def tag_key?(key)
    key.is_a?(Prism::SymbolNode) && key.unescaped.to_sym == TAG
  end

  def loads_handoff_fakes?(node)
    return false unless LOAD_METHODS.include?(node.name) && node.receiver.nil?

    target = node.arguments&.arguments&.first
    target.is_a?(Prism::StringNode) && File.basename(target.unescaped, ".rb") == HANDOFF_FAKES_BASENAME
  end

  # True when the reference names a declared fake, or something inside one
  # such as TimekeepingHandoffFakeRelay::ENUM_COLUMNS. Comparing whole
  # qualified names, not only top-level ones, also catches a fake declared
  # compactly as `class Outer::Fake`, without flagging Outer's other constants.
  def fake_reference?(node, fake_constants)
    segments = constant_segments(node)
    return false if segments.nil?

    segments = segments.drop(1) if segments.first == TOP_LEVEL_NAMESPACE && segments.size > 1
    (1..segments.size).any? { |length| fake_constants.include?(segments.first(length).join("::")) }
  end

  # The names along a constant path, or nil when it starts from an expression
  # such as `record.class::Name`, which cannot be resolved from source.
  def constant_segments(node)
    case node
    when Prism::ConstantReadNode
      [node.name]
    when Prism::ConstantPathNode
      return [node.name] if node.parent.nil?

      parent = constant_segments(node.parent)
      parent && [*parent, node.name]
    end
  end

  def declared_constants(node, namespace)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = [namespace, node.constant_path.slice.delete_prefix("::")].compact.join("::")
      [name, *declared_constants(node.body, name)].compact
    when nil
      []
    else
      node.compact_child_nodes.flat_map { |child| declared_constants(child, namespace) }
    end
  end
  private_class_method :walk, :walk_call, :group_call?, :example_call?, :rspec_receiver?, :tag_setting,
                       :tag_key?, :loads_handoff_fakes?, :fake_reference?, :constant_segments, :declared_constants
end
