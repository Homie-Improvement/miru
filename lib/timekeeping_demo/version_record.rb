# frozen_string_literal: true

require "digest"
require "open3"

module TimekeepingDemo
  # Which source each demo application runs: the HEAD commit, the git tree of
  # the application's own files, and whether the working tree differs from
  # HEAD there. An uncommitted change also gets a digest, so two different
  # edits on one commit are never recorded as the same version.
  module VersionRecord
    class GitError < StandardError; end

    # tree: the git object naming the application's source at HEAD.
    # paths: the pathspec its working-tree changes are read from.
    APPLICATIONS = {
      "monolith" => { tree: "HEAD^{tree}", paths: [".", ":(exclude)timekeeping"] },
      "timekeeping" => { tree: "HEAD:timekeeping", paths: ["timekeeping"] }
    }.freeze

    module_function

    # Answers a hash of application name to "revision", "tree", "dirty" and,
    # when dirty, "diff_digest". Raises GitError when root is not a git work
    # tree.
    def capture(root:)
      revision = git(root, "rev-parse", "HEAD")
      APPLICATIONS.to_h do |name, source|
        [name, entry(root, revision, source)]
      end
    end

    def entry(root, revision, source)
      changes = working_changes(root, source.fetch(:paths))
      record = { "revision" => revision, "tree" => git(root, "rev-parse", source.fetch(:tree)), "dirty" => !changes.empty? }
      record["diff_digest"] = Digest::SHA256.hexdigest(changes) unless changes.empty?
      record
    end

    # Tracked edits as a diff, plus the content id of every new file Git does
    # not ignore; empty when the application's files match HEAD.
    def working_changes(root, paths)
      diff = git(root, "diff", "--binary", "HEAD", "--", *paths)
      untracked = git(root, "ls-files", "-z", "--others", "--exclude-standard", "--", *paths).split("\0")
      untracked_ids = untracked.empty? ? [] : git(root, "hash-object", "--stdin-paths", stdin: untracked.join("\n")).lines
      [diff, untracked.zip(untracked_ids.map(&:chomp)).map { |pair| pair.join(" ") }.join("\n")]
        .reject(&:empty?).join("\n")
    end

    def git(root, *args, stdin: "")
      output, status = Open3.capture2("git", *args, chdir: root, stdin_data: stdin)
      raise GitError, "git #{args.first} failed in #{root}" unless status.success?

      output.strip
    end
  end
end
