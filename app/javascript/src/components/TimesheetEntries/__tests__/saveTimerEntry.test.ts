import {
  AxiosError,
  AxiosHeaders,
  type AxiosAdapter,
  type InternalAxiosRequestConfig,
} from "axios";
import { MutationObserver } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";

import api from "apis/api";
import { newIdempotencyKey } from "apis/idempotency";
import { queryClient } from "../../../lib/queryClient";
import { saveTimerEntry, type SaveTimerVariables } from "../saveTimerEntry";

vi.mock("StyledComponents", () => ({
  Toastr: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
}));

vi.mock("utils/runtimeRecovery", () => ({ reportClientError: vi.fn() }));

type TimerSend = { key: unknown; body: unknown };

// Fails the first `failures` sends as a lost connection, then answers 200,
// recording the key and body of every send.
const flakyTimerAdapter = (
  failures: number,
  sends: TimerSend[]
): AxiosAdapter => {
  let remainingFailures = failures;

  return (config: InternalAxiosRequestConfig) => {
    sends.push({
      key: AxiosHeaders.from(config.headers).get("Idempotency-Key"),
      body: config.data,
    });
    if (remainingFailures > 0) {
      remainingFailures -= 1;

      return Promise.reject(
        new AxiosError("Network Error", AxiosError.ERR_NETWORK, config)
      );
    }

    return Promise.resolve({
      config,
      status: 200,
      statusText: "",
      headers: {},
      data: { entry: { id: 1 } },
    });
  };
};

const timerVariables = (duration: number): SaveTimerVariables => ({
  entry: {
    project_id: 3,
    timesheet_entry: {
      work_date: "2026-01-05",
      duration,
      note: "timer",
      bill_status: "unbilled",
    },
  },
  userId: 9,
  idempotencyKey: newIdempotencyKey(),
});

const runTimerSave = (variables: SaveTimerVariables) =>
  new MutationObserver(queryClient, { mutationFn: saveTimerEntry }).mutate(
    variables
  );

describe("saveTimerEntry under the app's mutation retry", () => {
  const originalAdapter = api.defaults.adapter;

  afterEach(() => {
    api.defaults.adapter = originalAdapter;
  });

  it("resends a failed timer save with the same key and body", async () => {
    const sends: TimerSend[] = [];
    api.defaults.adapter = flakyTimerAdapter(1, sends);
    const variables = timerVariables(30);

    await runTimerSave(variables);

    expect(sends).toHaveLength(2);
    expect(sends[0].key).toBe(variables.idempotencyKey);
    expect(sends[1].key).toBe(sends[0].key);
    expect(sends[1].body).toEqual(sends[0].body);
  }, 10_000);

  it("sends a different key for each timer save the user makes", async () => {
    const sends: TimerSend[] = [];
    api.defaults.adapter = flakyTimerAdapter(0, sends);

    await runTimerSave(timerVariables(30));
    await runTimerSave(timerVariables(30));

    expect(sends).toHaveLength(2);
    expect(sends[0].key).not.toBe(sends[1].key);
  });

  it("refuses a timer under one minute without sending anything", async () => {
    const sends: TimerSend[] = [];
    api.defaults.adapter = flakyTimerAdapter(0, sends);

    await expect(saveTimerEntry(timerVariables(0))).rejects.toThrow();

    expect(sends).toHaveLength(0);
  });
});
