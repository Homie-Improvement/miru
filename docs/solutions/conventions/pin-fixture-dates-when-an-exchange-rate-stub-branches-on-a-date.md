---
module: reports
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - currency_conversion
  - factories
tags:
  - flaky-spec
  - exchange-rate-stub
  - factory-dates
  - base-currency
applies_when:
  - A spec stubs get_exchange_rate (or a similar rate lookup) with a value that depends on the date passed in
  - A record created in that spec is converted to base currency using its own date
---

# Pin fixture dates when an exchange-rate stub branches on a date

## Context

In `spec/models/reports_currency_calculation_spec.rb`, the currency specs stub `get_exchange_rate` with a date check. The stub returns 1.16 when the date equals `historical_payment_date` (five days ago) and 1.18 for every other date. Most invoices in the file set `issue_date: Date.current`. The `project_invoice` fixture did not, so the invoice factory chose the date.

On runs where that date was five days ago, the invoice converted at 1.16 instead of 1.18. The effective hourly rate then came out as 165.71 instead of the expected 168.57, and "calculates effective hourly rate in base currency" failed. On all other runs it passed.

## Solution

Give every record that reaches a date-branching rate stub an explicit date that the stub's special branch cannot match:

```ruby
invoice = create(:invoice, client: eur_client, company: company, currency: "EUR", amount: 2000.00, status: :paid,
                            issue_date: Date.current)
```

When you add a fixture to a spec like this, check which date field the conversion reads. Set that field yourself. Do not rely on the factory default.

## Why it matters

A stub that branches on a date turns every factory-chosen date into a hidden input to the assertion. The spec then passes or fails depending on the random date, not on the code. Such failures are hard to trace. They do not reproduce on demand, and they show up in other people's pull requests as unrelated CI failures. A fixed date makes the spec give the same result on every run.

## Evidence

- PR #575 changes `spec/models/reports_currency_calculation_spec.rb`. It adds `issue_date: Date.current` to the `project_invoice` fixture and changes no assertion.
- Issue #574, which PR #575 closes, gives the failing line: `expected 0.16571428571428571428571428571429e3 to be within 0.01 of 168.57`. It also states the stub's rule (`date == historical_payment_date ? 1.16 : 1.18`) and the five-day-ago historical date.
- Verification step, not shown by the diff: read the invoice factory and confirm that its `issue_date` default can land on five days ago.
