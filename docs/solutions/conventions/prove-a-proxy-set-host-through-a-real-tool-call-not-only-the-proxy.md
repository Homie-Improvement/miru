---
module: app/mcp
date: 2026-11-15
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - mcp_tools
  - api_proxy
  - mcp_controller
tags:
  - mcp
  - host-header
  - api-proxy
  - rspec
  - layered-tests
applies_when:
  - A rule depends on MCP::Miru::ApiProxy setting a request value itself
  - A layer above the proxy (BaseTool or McpController) builds the arguments it passes in
---

# Prove a proxy-set Host through a real tool call, not only the proxy

## Context

`MCP::Miru::ApiProxy` runs MCP tool calls as internal Rack requests. It sets `HTTP_HOST` from `AppBaseUrl.current`, so no part of the app relies on the Host that a client sent. `spec/mcp/api_proxy_spec.rb` checked this and passed.

In production the rule did not hold. `McpController` put `host: request.host_with_port` into the tool context. `BaseTool#proxy_request` passed it as a `Host` header. `ApiProxy` then merged caller headers over its own. So every tool call over HTTP carried the client's Host. The proxy spec could not see this, because it called `ApiProxy.request` directly and passed no headers.

## Solution

PR #310 removed the override at each layer: the controller's `host:` entry, `BaseTool`'s `headers` argument, the `host_from` helper, and the `headers:` keyword of `ApiProxy.request`. It also tested the rule at each layer that callers actually use:

- **Tool level** (`spec/mcp/tools/base_tool_host_spec.rb`): a real read tool (`WorkspaceWhoamiTool`) and a real write tool (`TimeCreateTool`) are called with a `server_context` host that differs from the configured one. The spec asserts that the captured `HTTP_HOST` is the literal `configured-host.test`.
- **Controller level** (`spec/requests/api/v1/mcp/handle_spec.rb`): a `tools/call` is posted with `host! "attacker.test"`. The spec wraps `Rack::MockRequest#request` with `and_wrap_original`, so the real internal call still runs, and asserts `internal_hosts == ["configured-host.test"]`.
- **Proxy level** (`spec/mcp/api_proxy_spec.rb`): the spec asserts that a `headers:` keyword raises `ArgumentError` and that no request is sent.

When you review a change to a rule the proxy owns, look for at least one example that enters through a tool or through `POST /api/v1/mcp`. A spec on the proxy alone does not count.

## Why it matters

The values that break a proxy-owned rule come from the layers above it. A spec that skips those layers also skips the bug. The tool-level and controller-level examples fail if any layer passes request data through again. A proxy-only spec does not run those layers; the new api_proxy_spec example fails only if ApiProxy.request accepts a headers keyword again, not if a layer above finds another way to pass request data.

## Evidence

- PR #310 (closes issue #301). Issue #301 says the new `api_proxy_spec` missed the override because it called `ApiProxy` directly, without `BaseTool`'s headers.
- `app/mcp/tools/base_tool.rb` in PR #310: `headers["Host"] = host` and `host_from` are removed.
- `app/mcp/api_proxy.rb` in PR #310: the `headers: {}` keyword and `.merge(headers)` are removed, and `request_headers` sets `"HTTP_HOST" => configured_host`.
- `app/controllers/api/v1/mcp_controller.rb` in PR #310: `host: request.host_with_port` is removed from `mcp_server_context`.
- `spec/mcp/tools/base_tool_host_spec.rb` and `spec/requests/api/v1/mcp/handle_spec.rb` in PR #310 add the tool-level and controller-level examples described above.
