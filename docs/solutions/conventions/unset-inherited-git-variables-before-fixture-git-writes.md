---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - development_workflow
tags:
  - git
  - git-dir
  - test-fixture
  - environment-variables
  - open3
applies_when:
  - A spec helper runs git init, add or commit in a temporary directory
  - The suite may run under a git hook or a tool that exports GIT_DIR or GIT_WORK_TREE
---

# Unset inherited GIT_* variables before fixture git writes

## Context

`TimekeepingDotenvTree.build(..., own_git: true)` runs `git init`, `git add --all` and `git commit` inside a temporary tree. It passes `chdir:` to pick the directory.

`chdir:` does not choose the repository when git variables are set. `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and similar variables override the working directory. A spec run started from a git hook, or from a tool that exports them, passes them to every child. The fixture commit then lands in that other repository, which is often the developer's own checkout.

## Solution

Unset every inherited `GIT_*` variable for each git command the helper runs. Pass them as `nil` in the environment hash, so only the child is affected:

```ruby
def git(tree, *args)
  unset_git_variables = ENV.keys.grep(/\AGIT_/).index_with(nil)
  output, status = Open3.capture2e(unset_git_variables, "git", *args, chdir: tree)
  raise GitError, "git failed in #{tree}: #{output}" unless status.success?

  output
end
```

Match the whole prefix, not a short list of names, so a variable added later is covered too. Also give the commit its own identity with `-c`, and use `--no-verify` and `commit.gpgsign=false`, so the user's config and hooks do not change the result.

## Why it matters

On most machines the variables are unset, so the bug does not show in local runs. When it does show, it writes a commit into someone else's history, which is harder to undo than a failed test.

## Evidence

- PR #468 adds the `git` helper in `spec/support/timekeeping/dotenv_tree.rb`, which unsets every `GIT_*` key before each command, and `GIT_IDENTITY` with `commit.gpgsign=false`.
- The code review on this pull request ran a reproduction with temporary repositories and `GIT_DIR` and `GIT_WORK_TREE` pointing at another repository. Before the fix, the other repository's HEAD changed, its last commit subject was `Temporary dotenv tree`, and no fixture repository existed. After the fix, the other repository's HEAD did not change and the fixture repository existed.
- `spec/lib/timekeeping_demo/boot_database_isolation_live_spec.rb` checks that building an own-git tree leaves the checkout's HEAD and index status unchanged.
