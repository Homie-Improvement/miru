---
module: Timekeeping::Handoff
date: 2026-11-14
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::Handoff::MoneySnapshotFile
  - Timekeeping::Handoff::ReportDirectory
tags:
  - rspec
  - round-trip
  - multi-tenant
  - spec-merge
  - serialization
applies_when:
  - A spec dumps and loads a snapshot keyed by company id, where each company holds its own map of value keys
  - Several round-trip examples are being merged into one owner example
---

# Give each company its own keys in multi-company round-trip specs

## Context

`Timekeeping::Handoff::MoneySnapshotFile` writes a money snapshot to a file and reads it back. The snapshot maps each company id to a hash of values, keyed by arrays such as `[:invoice, 9, :amount]`. A file that loses or invents values would make every resumed handoff report a false money change, or hide a real one.

The spec had three overlapping round-trip examples, and they were merged into one. The first merged version gave companies 101 and 202 the same seven value keys. The values differed, but the key sets were identical. Two of the three removed examples had given each company a different set of keys; the third ("keeps each company's money under its own company id when two companies share the same value keys") gave both companies the same three keys, which the merged example keeps as its shared keys.

## Solution

In a multi-company round trip, make the key sets differ in both directions, and assert that each company comes back with only its own keys:

- Keep some keys shared, so the spec still proves that two companies with the same key keep their own values.
- Give each company at least one key the other lacks. In the merged example, company 202 has `[:payment, 9, :amount]`, which company 101 does not have. Company 202 lacks `[:invoice, 9, :discount]` and `[:invoice, 9, :currency]`, which company 101 has.
- Assert absence as well as equality:

```ruby
expect(loaded).to eq(snapshots)
expect(loaded[101][:values]).not_to have_key([:payment, 9, :amount])
expect(loaded[202][:values]).not_to have_key([:invoice, 9, :discount])
expect(loaded[202][:values]).not_to have_key([:invoice, 9, :currency])
```

When you fold several examples into one, treat each removed example's input shape as a case to keep. Taking the union of its values is not enough. Shapes include which keys each tenant has and which files exist at the moment of a read.

## Why it matters

Some formats line every company up against one shared key list. Others pad a company with another company's keys, or drop keys the first company lacks. If both companies hold the same keys, all of these formats still produce equal output, so the spec passes. The bug then shows up only in production data, where companies rarely share a key set.

The current code passes with either input, so nothing fails to warn you that coverage was lost. The only guard is an input built to tell the formats apart.

The same rule applied in `ReportDirectory`. One removed example read the money file back before any checkpoint existed. The merged owner restored that order: it reads the money back, and checks that a later generation refuses it, before it writes the checkpoint. Without that step, the merged spec would no longer test reading a directory that holds only the money file.

## Evidence

- PR #272, `spec/lib/timekeeping/handoff/money_snapshot_file_spec.rb`: the merged example "round-trips two companies sharing value keys with exact decimals, types, nils and their own company ids" gives company 202 the key `[:payment, 9, :amount]`. It leaves the `:discount` and `:currency` keys out of company 202. It asserts with `not_to have_key` that neither company picks up the other's keys.
- PR #272 build review, round 2: the review found that the first merged input gave both companies identical key sets. To answer it, the author temporarily wrapped `MoneySnapshotFile.load` so that every company got the union of all keys. With that change, the spec run gave 3 examples and 1 failure, in the merged round trip. With the code restored, it gave 3 examples and 0 failures.
- PR #272, `spec/lib/timekeeping/handoff/report_directory_spec.rb`: the merged owner calls `read_money_before` for generation 2 and expects `described_class::Unreadable` for generation 3. Both checks run before `write_checkpoint`, which keeps the money-only case that a code review asked to restore.
