---
module: mcp
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/initializers/mcp_spec.rb in PR #198 raises inside a tool and sends tools/call through server.handle_json so the SDK calls the reporter; spec/mcp/stdio_transport_spec.rb runs the real no-argument StdioTransport#open on swapped $stdin/$stdout under Timeout.timeout(5) and JSON-parses every output line."
audience: both
related_components:
  - mcp
  - dependency_upgrades
tags:
  - sdk-upgrade
  - mcp
  - stdio-transport
  - exception-reporter
  - contract-tests
applies_when:
  - Upgrading a gem whose API the app calls or hands callbacks to
  - Adding specs for SDK call sites that had no tests before an upgrade
---

# Drive SDK call sites through the SDK in upgrade specs

## Context

When a gem crosses a major version, the risk is that the gem now calls the app differently, or the app's call no longer fits the gem. The `mcp` gem moved from 0.25.0 to 1.8.1 here. Two call sites had no specs: the stdio transport that `bin/miru-mcp` opens, and the `exception_reporter` set in `config/initializers/mcp.rb`.

Two tempting specs prove nothing about the upgrade:

- Calling the app's reporter lambda directly. The lambda is app code, so the spec passes on both gem versions even if the SDK stops calling it or passes other arguments.
- Checking that the transport responds to `open`. That passes even if `open` now needs an argument, while the binary still calls it with none.

## Solution

Make the spec cross the SDK boundary in the same shape the app does.

- **Callbacks the SDK invokes:** make the SDK invoke them. Build a server through `MCP::Miru::ServerFactory.build`, stub one tool's `call` to raise, send a `tools/call` request through `server.handle_json`, and assert on what the callback did (here: one `[MCP] RuntimeError: tool exploded` line in `Rails.logger.error`, with no bearer token in the log).
- **Methods the app calls:** make the exact call the app makes. For a blocking stdio loop, swap `$stdin` for a `StringIO` holding one request line then end of input, swap `$stdout` for a capturing `StringIO`, restore both in `ensure`, and wrap the call in `Timeout.timeout`. End of input lets the loop return; the timeout turns a hang into a failure instead of a stuck suite.
- **Protocol output:** parse every non-blank output line and let a parse error fail the example. A stdio client cannot read a stream mixed with diagnostics, so skipping unparseable lines hides a broken stream.
- Keep one version-floor assertion, in the example named for the advisory. Copies in unrelated examples fail with a version message instead of the behaviour they are named for.

## Why it matters

An upgrade spec earns its place only if it fails on the breakage the upgrade can cause. A spec that exercises only app code, or only method existence, is green on both versions, so it gives false confidence exactly when the gem's contract changes. Driving the real call also catches a hang, which a stdio binary would otherwise show only in production when the client pipe stays open.

## Evidence

- PR #198, `spec/initializers/mcp_spec.rb`: the example stubs `MCP::Miru::Tools::WorkspaceWhoamiTool.call` to raise, calls `server.handle_json(request.to_json)`, and expects `logged.count("[MCP] RuntimeError: tool exploded")` to eq 1 and the log not to include `secret-mcp-token-123`. Its comment states it fails "if the SDK stops calling the configured reporter or changes the arguments it passes".
- PR #198, `spec/mcp/stdio_transport_spec.rb`: the `run_stdio_transport` helper swaps `$stdin`/`$stdout` for `StringIO`, runs `Timeout.timeout(5) { described_class.new(server).open }`, restores the streams in `ensure`, and maps every non-empty line through `JSON.parse`. Its comment notes that `bin/miru-mcp` calls `open` with no arguments and that a non-JSON line raises.
- PR #198, `spec/mcp/server_factory_spec.rb`: the only `Gem.loaded_specs.fetch("mcp").version` floor check sits in the example named for GHSA-4m5j-jjfc-97gx.
