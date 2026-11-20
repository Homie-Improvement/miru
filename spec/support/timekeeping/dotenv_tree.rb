# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Builds a temporary app tree that boots Rails with the tree itself as
# Rails.root, so a dotenv file written there is read only by children started
# in the tree, never by other test processes sharing the real checkout.
module TimekeepingDotenvTree
  # Ruby resolves symlinks when it requires a file, and these files find the
  # app root from their own location, so they are real copies in the tree.
  COPIED_FILES = %w[config/application.rb config/environment.rb spec/rails_helper.rb].freeze
  COPIED_DIRS = COPIED_FILES.map { |path| File.dirname(path) }.uniq.freeze
  # Fresh directories, so the children's caches and logs stay out of the checkout.
  OWN_DIRS = %w[tmp log].freeze

  module_function

  def build(tree, dotenv:, root: Rails.root)
    root.children.each do |entry|
      name = entry.basename.to_s
      next if name.start_with?(".env") || OWN_DIRS.include?(name) || COPIED_DIRS.include?(name)

      File.symlink(entry.to_s, File.join(tree, name))
    end
    OWN_DIRS.each { |dir| Dir.mkdir(File.join(tree, dir)) }
    COPIED_DIRS.each { |dir| build_copied_dir(root.join(dir), File.join(tree, dir)) }
    File.write(File.join(tree, ".env.test.local"), dotenv)
  end

  def build_copied_dir(source, target)
    Dir.mkdir(target)
    source.children.each do |entry|
      path = File.join(target, entry.basename.to_s)
      if COPIED_FILES.include?(entry.relative_path_from(source.parent).to_s)
        FileUtils.cp(entry.to_s, path)
      else
        File.symlink(entry.to_s, path)
      end
    end
  end
end
