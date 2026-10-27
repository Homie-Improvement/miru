---
module: Timekeeping::LocalOwner
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "PR #189 reports that removing company_id from both entry reads fails the merged foreign-id example in spec/services/timekeeping/local_owner_tenancy_spec.rb."
audience: both
related_components:
  - Timekeeping::LocalEntry
tags:
  - mutation-testing
  - tenancy
  - local-owner
applies_when:
  - Checking that a cross-company refusal test detects an intentionally introduced fault
  - Interpreting a passing test after removing one of several checks for the same refusal
---

# Check redundant reads before changing a surviving fault test

## Context

A passing test after an intentional code fault does not always mean coverage is missing. Another check can still prevent the wrong outcome.

For the LocalOwner update path examined in PR #189, both `locked_entries` and `reserved_rows` filter by `company_id`. Removing that filter only from `locked_entries` leaves the second read enforcing the company boundary. The update still answers `not_found`.

## Solution

First establish whether the temporary fault actually permits the outcome the test forbids. Trace each read that supplies the entry to the update.

For this foreign-entry check, temporarily remove the company filter from both reads. Run the foreign-id example, confirm that it fails, then restore both filters.

Keep the fixture focused on the company boundary. Use one user with the same role in both companies. Otherwise, a different user or role can supply another reason to refuse the update.

If removing only one filter leaves the example green, record the remaining protection. Do not change a correct refusal test merely to detect that single edit.

This guidance concerns a test of the refusal outcome. A separate requirement that each query be scoped would need its own direct check.

## Why it matters

Changing a test before tracing the remaining checks confuses redundant protection with missing coverage. It can also bind the test to one query instead of the company boundary it protects.

A useful temporary fault must enable the forbidden outcome, not just remove one expression associated with it.

## Evidence

PR #189 consolidates the foreign-id case in `spec/services/timekeeping/local_owner_tenancy_spec.rb`. The example uses one user with the owner role in both companies. It checks the literal `not_found` response, agreement with a missing ID, unchanged entry attributes, and unchanged counts across four tables.

PR #189's test plan reports that removing `company_id` from both entry reads made the merged foreign-id example fail. It also reports that the application code was restored afterward. The pull request changes specs only; it does not remove either production filter.
