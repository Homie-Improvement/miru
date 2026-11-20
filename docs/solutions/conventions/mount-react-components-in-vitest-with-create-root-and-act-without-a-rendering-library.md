---
module: TimesheetEntries
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - FloatingTimer
  - queryClient
tags:
  - vitest
  - react
  - component-tests
  - jsdom
  - radix-dialog
applies_when:
  - A test needs to click a real button in a React component, and the repository has no component-rendering library such as @testing-library/react.
---

# Mount React components in Vitest with createRoot and act, not a new library

## Context

Issue #339 deferred a test that clicks FloatingTimer's Save button. The stated reason was that the repository has no component-rendering library. That reason does not hold. React's own `act` and `createRoot` from `react-dom/client` can mount a component in jsdom and drive it with plain DOM events. Adding a library would change `package.json` and `pnpm-lock.yaml` for one test.

## Solution

Write the test as a `.tsx` file and import `React`. The project compiles JSX with the classic runtime, so JSX needs `React` in scope.

Set up and tear down like this:

```tsx
beforeEach(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});
```

`IS_REACT_ACT_ENVIRONMENT` tells React that the code runs under `act`. Without it, React warns and may not flush updates before the assertions run.

Wrap every render, click and timer advance in `await act(async () => ...)`. Click with `dispatchEvent(new MouseEvent("click", { bubbles: true }))`. The event must bubble because React listens at the root.

Find buttons in `document.body`, not in the container. Radix Dialog renders its content into a portal outside the container, so a search of the container does not find the dialog's Save button. Find buttons by their translated label, with `i18n.t(...)`, so the test follows copy changes.

Mount under the app's exported `queryClient` inside `QueryClientProvider`, and call `queryClient.clear()` in `afterEach`. Then the test runs the app's real query and mutation settings, and cached queries do not carry into the next test.

## Why it matters

A test of an extracted helper does not run the component's event handler. Code that the handler controls, such as when an idempotency key is created, is then untested. A rendering library is not needed to close that gap. Do not defer component tests for that reason, and do not add the dependency for one test.

## Evidence

PR #443 adds `app/javascript/src/components/TimesheetEntries/__tests__/FloatingTimer.saveRetry.test.tsx`. It imports `createRoot` from `react-dom/client` and `act` from `react`, sets `IS_REACT_ACT_ENVIRONMENT` in `beforeEach`, and finds buttons with `document.body.querySelectorAll("button")` in its `buttonLabelled` helper. It mounts `FloatingTimer` under `QueryClientProvider` with the exported `queryClient`, clears that client in `afterEach`, and adds no dependency. Issue #339 records the earlier deferral, which cited the missing rendering library. The PR body reports that `pnpm test:js` passed with the new test.
