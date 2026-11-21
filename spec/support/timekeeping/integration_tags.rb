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
  # Blocks that run while an example runs, not while groups are declared, so
  # a `skip` or `pending` call inside one is a runtime call, not an example.
  RUNTIME_BLOCK_METHODS = %i[
    before after around prepend_before append_before prepend_after append_after let let! subject subject!
  ].freeze
  # The only example methods whose names count as passing examples: the x
  # forms, skip and pending never run, and the f forms are focus filters
  # that should not be committed.
  COUNTED_EXAMPLE_METHODS = %i[it specify example].freeze
  DISABLED_GROUP_METHODS = %i[xdescribe xcontext].freeze
  # Metadata keys that stop an example, or every example in a group, from
  # running. Written as a bare symbol or as a key, whatever its value.
  SKIP_METADATA = %i[skip pending].freeze
  LOAD_METHODS = %i[require require_relative load].freeze
  HANDOFF_FAKES_BASENAME = "handoff_fakes"
  # Object::Name and ::Name both name the top-level constant Name.
  TOP_LEVEL_NAMESPACE = :Object

  module_function

  # Every violation in one spec file's source, in source order.
  def violations(path, source, fake_constants: handoff_fake_constants)
    found = []
    walk(Prism.parse(source).value, false, false, fake_constants) do |node, kind, detail|
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

  # The names of the examples in one spec file's source that would run and
  # pass, in source order. Examples that are skipped, pending, focused, or
  # under a skipped group are left out, so none of them can count as proof.
  # Raises ArgumentError naming the line of a counted example whose name is
  # not a plain string literal, because its text cannot be read from source.
  def example_names(source)
    example_names_in(Prism.parse(source).value, false).freeze
  end

  # disabled is whether a group above node is skipped or pending. It is
  # never cleared, so a plain group inside a skipped one stays skipped.
  # Example bodies and hooks are not read: calls there are not declarations.
  def example_names_in(node, disabled)
    if node.is_a?(Prism::CallNode)
      return counted_example?(node) && !disabled ? [example_name(node)] : [] if example_call?(node)
      return [] if RUNTIME_BLOCK_METHODS.include?(node.name)

      disabled ||= group_call?(node) && disabled_group?(node)
    end
    node.compact_child_nodes.flat_map { |child| example_names_in(child, disabled) }
  end

  # An example with no block is reported by RSpec as pending, not run.
  def counted_example?(node)
    COUNTED_EXAMPLE_METHODS.include?(node.name) && !node.block.nil? && !skip_metadata?(node)
  end

  def disabled_group?(node)
    DISABLED_GROUP_METHODS.include?(node.name) || skip_metadata?(node)
  end

  def skip_metadata?(node)
    (node.arguments&.arguments || []).any? do |argument|
      case argument
      when Prism::SymbolNode
        skip_symbol?(argument)
      when Prism::KeywordHashNode, Prism::HashNode
        argument.elements.any? { |element| element.is_a?(Prism::AssocNode) && skip_symbol?(element.key) }
      else
        false
      end
    end
  end

  def skip_symbol?(node)
    node.is_a?(Prism::SymbolNode) && SKIP_METADATA.include?(node.unescaped.to_sym)
  end

  def example_name(node)
    name = node.arguments&.arguments&.first
    unless name.is_a?(Prism::StringNode)
      raise ArgumentError,
            "the example name at line #{node.location.start_line} is not a plain string literal: #{node.slice.lines.first.strip}"
    end

    name.unescaped.dup.freeze
  end

  # tagged is whether the nearest committed_data setting above node is true.
  # runtime is whether node sits inside an example body or a hook, where
  # group and example methods are calls rather than declarations.
  def walk(node, tagged, runtime, fake_constants, &report)
    case node
    when Prism::CallNode
      walk_call(node, tagged, runtime, fake_constants, &report)
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      # A path is checked whole; its parent segments are not separate references.
      if fake_reference?(node, fake_constants)
        report.call(node, :loads_handoff_fakes, "references #{node.slice}")
      end
    else
      node.compact_child_nodes.each { |child| walk(child, tagged, runtime, fake_constants, &report) }
    end
  end

  def walk_call(node, tagged, runtime, fake_constants, &report)
    report.call(node, :loads_handoff_fakes, node.slice) if loads_handoff_fakes?(node)

    example = !runtime && example_call?(node)
    tagged = tag_setting(node).fetch(:value, tagged) if example || (!runtime && group_call?(node))
    report.call(node, :missing_committed_data, "example lacks committed_data: true") if example && !tagged
    runtime ||= example || RUNTIME_BLOCK_METHODS.include?(node.name)
    node.compact_child_nodes.each { |child| walk(child, tagged, runtime, fake_constants, &report) }
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

  # A bare call, or one through Kernel (Kernel.require is the same call).
  def loads_handoff_fakes?(node)
    return false unless LOAD_METHODS.include?(node.name)
    return false unless node.receiver.nil? || top_level_segments(node.receiver) == [:Kernel]

    target = node.arguments&.arguments&.first
    target.is_a?(Prism::StringNode) && File.basename(target.unescaped, ".rb") == HANDOFF_FAKES_BASENAME
  end

  # True when the reference names a declared fake, or something inside one
  # such as TimekeepingHandoffFakeRelay::ENUM_COLUMNS. Comparing whole
  # qualified names, not only top-level ones, also catches a fake declared
  # compactly as `class Outer::Fake`, without flagging Outer's other constants.
  def fake_reference?(node, fake_constants)
    segments = top_level_segments(node)
    return false if segments.nil?

    (1..segments.size).any? { |length| fake_constants.include?(segments.first(length).join("::")) }
  end

  # The constant path's names from the top-level namespace, with a leading
  # Object segment dropped, or nil when the path cannot be resolved.
  def top_level_segments(node)
    segments = constant_segments(node)
    return segments unless segments && segments.first == TOP_LEVEL_NAMESPACE && segments.size > 1

    segments.drop(1)
  end

  # The names along a constant path, or nil when it is not a constant or
  # starts from an expression such as `record.class::Name`, which cannot be
  # resolved from source.
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
  private_class_method :example_names_in, :counted_example?, :disabled_group?, :skip_metadata?, :skip_symbol?,
                       :example_name,
                       :walk, :walk_call, :group_call?, :example_call?, :rspec_receiver?, :tag_setting,
                       :tag_key?, :loads_handoff_fakes?, :fake_reference?, :top_level_segments,
                       :constant_segments, :declared_constants
end
