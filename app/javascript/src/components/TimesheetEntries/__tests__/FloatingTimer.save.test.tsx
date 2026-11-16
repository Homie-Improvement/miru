import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import {
  AxiosError,
  AxiosHeaders,
  type AxiosAdapter,
  type AxiosResponse,
  type InternalAxiosRequestConfig,
} from "axios";
import { QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import api from "apis/api";
import { persistTimerDeck, TIMER_DECK_VERSION } from "utils/timeTrackingTimer";
import { i18n } from "../../../i18n";
import { queryClient } from "../../../lib/queryClient";
import FloatingTimer from "../FloatingTimer";

vi.mock("StyledComponents", () => ({
  Toastr: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
}));

vi.mock("utils/runtimeRecovery", () => ({ reportClientError: vi.fn() }));

// Tells React this is a test environment, so act() flushes renders and
// effects instead of warning that updates escaped it.
(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

// One second before midnight UTC: the click happens on 2026-01-05, and React
// Query's first retry delay of 1000 ms lands the retry on 2026-01-06. A
// work_date or key created again inside the retry would differ.
const CLICK_TIME = new Date("2026-01-05T23:59:59.000Z");
const CLICK_DAY = "2026-01-05";
const RETRY_DAY = "2026-01-06";
const FIRST_RETRY_DELAY_MS = 1000;

const SEEDED_PROJECT = {
  id: 3,
  name: "Website",
  client_name: "Acme",
  billable: true,
};

type TimesheetEntrySend = { key: string | null; body: string; sentAt: string };

const okResponse = (
  config: InternalAxiosRequestConfig,
  data: unknown
): Promise<AxiosResponse> =>
  Promise.resolve({ config, status: 200, statusText: "", headers: {}, data });

// Answers the timer's background requests and records every POST to
// /timesheet_entry, failing the first `failures` of them as a lost connection.
const timesheetEntryAdapter = (
  failures: number,
  sends: TimesheetEntrySend[]
): AxiosAdapter => {
  let remainingFailures = failures;

  return (config: InternalAxiosRequestConfig) => {
    const url = config.url ?? "";

    if (url === "/projects") {
      return okResponse(config, { projects: [SEEDED_PROJECT], clients: [] });
    }

    if (url === "/desktop/current_timer") {
      return okResponse(config, { current_timer: null });
    }

    if (config.method === "post" && url.startsWith("/timesheet_entry")) {
      sends.push({
        key: AxiosHeaders.from(config.headers).get("Idempotency-Key") as
          | string
          | null,
        body: config.data as string,
        sentAt: new Date().toISOString(),
      });

      if (remainingFailures > 0) {
        remainingFailures -= 1;

        return Promise.reject(
          new AxiosError("Network Error", AxiosError.ERR_NETWORK, config)
        );
      }

      return okResponse(config, { entry: { id: 1 } });
    }

    return Promise.reject(new Error(`Unexpected request to ${url}`));
  };
};

const seedPausedTimer = () =>
  persistTimerDeck({
    activeTimerId: "timer-1",
    timers: [
      {
        id: "timer-1",
        isRunning: false,
        startTime: null,
        elapsedTime: 90 * 60_000,
        project: SEEDED_PROJECT.name,
        client: SEEDED_PROJECT.client_name,
        description: "Fix login",
        projectId: SEEDED_PROJECT.id,
      },
    ],
    version: TIMER_DECK_VERSION,
  });

const advance = (ms: number) =>
  act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });

const buttonLabelled = (label: string): HTMLButtonElement => {
  const button = Array.from(document.querySelectorAll("button")).find(
    candidate => candidate.textContent?.trim() === label
  );
  if (!button) throw new Error(`No button labelled "${label}"`);

  return button;
};

const click = (label: string) =>
  act(async () => {
    buttonLabelled(label).click();
  });

describe("FloatingTimer Save under the app's mutation retry", () => {
  const originalAdapter = api.defaults.adapter;
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(CLICK_TIME);
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    api.defaults.adapter = originalAdapter;
    queryClient.clear();
    localStorage.clear();
    vi.useRealTimers();
  });

  it("retries a failed save with the click's key and body, and a second click sends a new key", async () => {
    const sends: TimesheetEntrySend[] = [];
    // The first click's send and its one retry fail; the second click succeeds.
    api.defaults.adapter = timesheetEntryAdapter(2, sends);
    seedPausedTimer();

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <FloatingTimer />
        </QueryClientProvider>
      );
    });
    await advance(50);

    await click(i18n.t("timer.stop"));
    await click(i18n.t("timeTracking.saveEntry"));
    await advance(50);

    expect(sends).toHaveLength(1);
    expect(sends[0].sentAt.startsWith(CLICK_DAY)).toBe(true);
    expect(JSON.parse(sends[0].body).timesheet_entry.work_date).toBe(CLICK_DAY);

    await advance(FIRST_RETRY_DELAY_MS);

    expect(sends).toHaveLength(2);
    expect(sends[1].sentAt.startsWith(RETRY_DAY)).toBe(true);
    expect(sends[0].key).toEqual(expect.any(String));
    expect(sends[1].key).toBe(sends[0].key);
    expect(sends[1].body).toBe(sends[0].body);

    // Both attempts failed, so the dialog stays open with Save enabled.
    await click(i18n.t("timeTracking.saveEntry"));
    await advance(50);

    expect(sends).toHaveLength(3);
    expect(sends[2].key).toEqual(expect.any(String));
    expect(sends[2].key).not.toBe(sends[0].key);
  });
});
