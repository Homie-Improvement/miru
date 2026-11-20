import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClientProvider } from "@tanstack/react-query";
import {
  AxiosError,
  AxiosHeaders,
  type AxiosAdapter,
  type AxiosResponse,
  type InternalAxiosRequestConfig,
} from "axios";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import api from "apis/api";
import {
  createTimerState,
  TIMER_DECK_VERSION,
  TIMER_STORAGE_KEY,
  type StoredTimerDeck,
} from "utils/timeTrackingTimer";
import { i18n } from "../../../i18n";
import { queryClient } from "../../../lib/queryClient";
import FloatingTimer from "../FloatingTimer";

vi.mock("StyledComponents", () => ({
  Toastr: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
}));

vi.mock("utils/runtimeRecovery", () => ({ reportClientError: vi.fn() }));

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}));

const SEEDED_PROJECT = { id: 3, name: "Apollo", client: "Acme" };

// One second before UTC midnight: React Query waits about a second before
// its retry, so a body rebuilt at retry time would carry the next day.
const CLICK_TIME = new Date("2026-01-05T23:59:59.500Z");
const CLICK_DAY = "2026-01-05";
const PAST_RETRY_DELAY_MS = 5_000;

type SaveSend = { key: string | null; body: unknown };

const okResponse = (
  config: InternalAxiosRequestConfig,
  data: unknown
): AxiosResponse => ({
  config,
  data,
  headers: {},
  status: 200,
  statusText: "",
});

// Answers every request the timer makes on its own. Records each timesheet
// entry create and fails the first `failures` of them as a lost connection.
const saveRecordingAdapter = (
  failures: number,
  sends: SaveSend[]
): AxiosAdapter => {
  let remainingFailures = failures;

  return async (config: InternalAxiosRequestConfig) => {
    const method = (config.method || "get").toLowerCase();
    const path = (config.url || "").split("?")[0];

    if (method === "post" && path === "/timesheet_entry") {
      const key = AxiosHeaders.from(config.headers).get("Idempotency-Key");
      sends.push({
        key: typeof key === "string" ? key : null,
        body: JSON.parse(String(config.data)),
      });
      if (remainingFailures > 0) {
        remainingFailures -= 1;
        throw new AxiosError("Network Error", AxiosError.ERR_NETWORK, config);
      }

      return okResponse(config, { entry: { id: sends.length } });
    }

    if (method === "get" && path === "/projects") {
      return okResponse(config, {
        clients: [],
        projects: [
          {
            id: SEEDED_PROJECT.id,
            name: SEEDED_PROJECT.name,
            client_name: SEEDED_PROJECT.client,
            billable: true,
          },
        ],
      });
    }

    if (path === "/desktop/current_timer") {
      return okResponse(config, { current_timer: null });
    }

    return okResponse(config, {});
  };
};

const seedStoppedTimer = (description: string) => {
  const timer = {
    ...createTimerState(),
    elapsedTime: 30 * 60 * 1000,
    project: SEEDED_PROJECT.name,
    client: SEEDED_PROJECT.client,
    projectId: SEEDED_PROJECT.id,
    description,
  };

  const deck: StoredTimerDeck = {
    activeTimerId: timer.id,
    timers: [timer],
    version: TIMER_DECK_VERSION,
  };

  localStorage.setItem(TIMER_STORAGE_KEY, JSON.stringify(deck));
};

const buttonLabelled = (label: string): HTMLButtonElement => {
  const button = Array.from(document.body.querySelectorAll("button")).find(
    candidate => candidate.textContent?.trim() === label
  );
  if (!button) throw new Error(`No button labelled "${label}"`);

  return button;
};

const click = async (label: string) => {
  await act(async () => {
    buttonLabelled(label).dispatchEvent(
      new MouseEvent("click", { bubbles: true })
    );
  });
};

const advance = async (ms: number) => {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
};

describe("FloatingTimer Save under the app's mutation retry", () => {
  const originalAdapter = api.defaults.adapter;
  let container: HTMLDivElement;
  let root: Root;

  const renderTimer = async (externalSyncKey: number) => {
    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <FloatingTimer externalSyncKey={externalSyncKey} />
        </QueryClientProvider>
      );
    });
    // Lets the project list and desktop timer requests settle.
    await advance(1_000);
  };

  beforeEach(() => {
    (
      globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }
    ).IS_REACT_ACT_ENVIRONMENT = true;
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

  it("retries a failed Save with the click's key and body, and a second Save gets a new key", async () => {
    const sends: SaveSend[] = [];
    api.defaults.adapter = saveRecordingAdapter(1, sends);
    seedStoppedTimer("first save");
    await renderTimer(0);

    // The render advanced the clock, so put it back just before midnight.
    vi.setSystemTime(CLICK_TIME);
    await click(i18n.t("timer.stop"));
    await click(i18n.t("timeTracking.saveEntry"));
    expect(sends).toHaveLength(1);

    await advance(PAST_RETRY_DELAY_MS);
    expect(new Date().toISOString().startsWith(CLICK_DAY)).toBe(false);

    expect(sends).toHaveLength(2);
    expect(sends[0].key).toEqual(expect.any(String));
    expect(sends[1].key).toBe(sends[0].key);
    expect(sends[1].body).toEqual(sends[0].body);
    expect(sends[1].body).toMatchObject({
      timesheet_entry: { work_date: CLICK_DAY, duration: 30 },
    });

    seedStoppedTimer("second save");
    await renderTimer(1);
    await click(i18n.t("timer.stop"));
    await click(i18n.t("timeTracking.saveEntry"));
    await advance(PAST_RETRY_DELAY_MS);

    expect(sends).toHaveLength(3);
    expect(sends[2].key).toEqual(expect.any(String));
    expect(sends[2].key).not.toBe(sends[0].key);
  });
});
