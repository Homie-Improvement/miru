# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# Builds a temporary app tree that boots Rails with the tree itself as
# Rails.root, so a dotenv file written there is read only by children started
# in the tree, never by other test processes sharing the real checkout.
module TimekeepingDotenvTree
  class GitError < StandardError; end

  # Ruby resolves symlinks when it requires a file, and these files find the
  # app root from their own location, so they are real copies in the tree.
  # The bin scripts are the ones `bin/timekeeping-demo up` runs for the
  # monolith: the launcher itself, its queue workers, and `bin/rails
  # db:prepare`; a symlinked copy would boot the checkout and read its .env
  # files instead of the tree's.
  COPIED_FILES = %w[
    config/application.rb config/environment.rb spec/rails_helper.rb
    bin/timekeeping-demo bin/timekeeping-demo-queue bin/rails
  ].freeze
  COPIED_DIRS = COPIED_FILES.map { |path| File.dirname(path) }.uniq.freeze
  # Top-level files that also load the app relative to themselves: rake reads
  # the Rakefile and puma reads config.ru.
  COPIED_TOP_LEVEL_FILES = %w[Rakefile config.ru].freeze
  # Fresh directories, so the children's caches and logs stay out of the checkout.
  OWN_DIRS = %w[tmp log].freeze
  GIT_DIR = ".git"
  # Git refuses to read these files through a symlink, so a tree with its own
  # repository gets real copies; without .gitignore the files the apps write
  # under tmp would count as changes.
  GIT_METADATA_FILES = %w[.gitignore .gitattributes].freeze
  GIT_IDENTITY = %w[-c user.name=timekeeping-dotenv-tree -c user.email=timekeeping-dotenv-tree@localhost
                    -c commit.gpgsign=false].freeze

  module_function

  # own_git: gives the tree a repository of its own, committed once, in place
  # of a symlink to the checkout's .git. The launcher's version capture runs
  # git in its root; against the checkout's index the symlinked directories
  # are untracked paths git cannot hash, so the launcher would exit.
  def build(tree, dotenv:, root: Rails.root, own_git: false)
    skipped = OWN_DIRS + COPIED_DIRS + COPIED_TOP_LEVEL_FILES
    skipped += [GIT_DIR, *GIT_METADATA_FILES] if own_git
    root.children.each do |entry|
      name = entry.basename.to_s
      next if name.start_with?(".env") || skipped.include?(name)

      File.symlink(entry.to_s, File.join(tree, name))
    end
    OWN_DIRS.each { |dir| Dir.mkdir(File.join(tree, dir)) }
    COPIED_DIRS.each { |dir| build_copied_dir(root.join(dir), File.join(tree, dir)) }
    COPIED_TOP_LEVEL_FILES.each { |name| FileUtils.cp(root.join(name).to_s, File.join(tree, name), preserve: true) }
    File.write(File.join(tree, ".env.test.local"), dotenv)
    commit_own_repository(tree, root) if own_git
  end

  def build_copied_dir(source, target)
    Dir.mkdir(target)
    source.children.each do |entry|
      path = File.join(target, entry.basename.to_s)
      if COPIED_FILES.include?(entry.relative_path_from(source.parent).to_s)
        FileUtils.cp(entry.to_s, path, preserve: true)
      else
        File.symlink(entry.to_s, path)
      end
    end
  end

  # Git stores each symlink as a link and never follows it, so committing the
  # tree stays small whatever the checkout holds.
  def commit_own_repository(tree, root)
    GIT_METADATA_FILES.each do |name|
      source = root.join(name)
      FileUtils.cp(source.to_s, File.join(tree, name)) if source.exist?
    end
    git(tree, "init", "--quiet")
    git(tree, "add", "--all")
    git(tree, *GIT_IDENTITY, "commit", "--quiet", "--no-verify", "--message", "Temporary dotenv tree")
  end

  def git(tree, *args)
    output, status = Open3.capture2e("git", *args, chdir: tree)
    raise GitError, "git failed in #{tree}: #{output}" unless status.success?

    output
  end
end
