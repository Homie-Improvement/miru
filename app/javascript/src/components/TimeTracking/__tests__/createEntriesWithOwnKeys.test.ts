import {
  AxiosHeaders,
  type AxiosAdapter,
  type InternalAxiosRequestConfig,
} from "axios";
import { afterEach, describe, expect, it, vi } from "vitest";

import api from "apis/api";
import { createEntriesWithOwnKeys } from "../createEntriesWithOwnKeys";

vi.mock("StyledComponents", () => ({
  Toastr: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
}));

vi.mock("utils/runtimeRecovery", () => ({ reportClientError: vi.fn() }));

describe("createEntriesWithOwnKeys for the copy-week action", () => {
  const originalAdapter = api.defaults.adapter;

  afterEach(() => {
    api.defaults.adapter = originalAdapter;
  });

  it("sends each copied entry under its own key", async () => {
    const keys: unknown[] = [];
    const recordingAdapter: AxiosAdapter = (
      config: InternalAxiosRequestConfig
    ) => {
      keys.push(AxiosHeaders.from(config.headers).get("Idempotency-Key"));

      return Promise.resolve({
        config,
        status: 200,
        statusText: "",
        headers: {},
        data: {},
      });
    };
    api.defaults.adapter = recordingAdapter;

    await createEntriesWithOwnKeys([{ n: 1 }, { n: 2 }, { n: 3 }], 4);

    expect(keys).toHaveLength(3);
    expect(new Set(keys).size).toBe(3);
  });
});
