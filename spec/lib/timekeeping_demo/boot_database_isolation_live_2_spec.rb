# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe TimekeepingDotenvTree do
  # "A spec boots the monolith and Timekeeping through bin/timekeeping-demo with a temporary dotenv file that sets conflicting DATABASE_URL, DB_USER and PG\* values, and asserts that each app's live connection reports its own distinct current_user."
  # The launcher captures versions after db:prepare and before starting any app. In a tree that
  # shares the checkout's git index, the symlinked app directories are untracked paths that
  # `git hash-object` cannot hash, so the launcher would exit and no app would ever boot.
  it "the launcher's version capture succeeds in a dotenv tree built with its own git repository, so the launcher does not exit before booting either app" do
    Dir.mktmpdir("boot-isolation-version-tree") do |dir|
      tree = File.realpath(dir)
      described_class.build(tree, dotenv: "PGAPPNAME=boot-isolation-version-probe\n", own_git: true)

      expect(File.symlink?(File.join(tree, ".git"))).to be(false)
      versions = TimekeepingDemo::VersionRecord.capture(root: tree)

      expect(versions.keys).to eq(%w[monolith timekeeping])
      expect(versions.values.map { |entry| entry.fetch("revision") }.uniq.size).to eq(1)
    end
  end
end
