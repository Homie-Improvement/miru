import {
  AxiosError,
  AxiosHeaders,
  type AxiosAdapter,
  type AxiosResponse,
  type InternalAxiosRequestConfig,
} from "axios";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import api, { timesheetEntryApi } from "../api";
import { newIdempotencyKey } from "../idempotency";

vi.mock("StyledComponents", () => ({
  Toastr: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
}));

vi.mock("utils/runtimeRecovery", () => ({ reportClientError: vi.fn() }));

const UUID_V4 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type Send = { method?: string; url?: string; key: string | undefined };

const sentKey = (config: InternalAxiosRequestConfig) => {
  const value = AxiosHeaders.from(config.headers).get("Idempotency-Key");

  return typeof value === "string" ? value : undefined;
};

const answer = (
  config: InternalAxiosRequestConfig,
  status: number
): AxiosResponse => ({
  config,
  status,
  statusText: "",
  headers: {},
  data: {},
});

// Answers each send with the next status in the script and records what was sent.
const scriptedAdapter = (statuses: number[], sends: Send[]): AxiosAdapter => {
  const remaining = [...statuses];

  return config => {
    sends.push({
      method: config.method,
      url: config.url,
      key: sentKey(config),
    });
    const status = remaining.shift() ?? 200;
    const response = answer(config, status);
    if (status >= 200 && status < 300) return Promise.resolve(response);

    return Promise.reject(
      new AxiosError(
        `status ${status}`,
        AxiosError.ERR_BAD_RESPONSE,
        config,
        null,
        response
      )
    );
  };
};

describe("timesheetEntryApi idempotency keys", () => {
  const originalAdapter = api.defaults.adapter;
  let sends: Send[];

  beforeEach(() => {
    sends = [];
  });

  afterEach(() => {
    api.defaults.adapter = originalAdapter;
    vi.unstubAllGlobals();
  });

  it("resends a create after a recovered 401 with the same UUID v4 key", async () => {
    api.defaults.adapter = scriptedAdapter([401, 200], sends);
    const sessionCheck = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal("fetch", sessionCheck);

    const key = newIdempotencyKey();
    await timesheetEntryApi.create({ project_id: 1 }, key);

    expect(sessionCheck).toHaveBeenCalledWith(
      "/api/v1/users/_me",
      expect.anything()
    );
    expect(sends).toHaveLength(2);
    expect(sends[0].key).toBe(key);
    expect(sends[1].key).toBe(sends[0].key);
    expect(sends[0].key).toMatch(UUID_V4);
  });

  it("sends a create answered 500 exactly once", async () => {
    api.defaults.adapter = scriptedAdapter([500], sends);

    await expect(
      timesheetEntryApi.create({ project_id: 1 }, newIdempotencyKey())
    ).rejects.toBeInstanceOf(AxiosError);

    expect(sends).toHaveLength(1);
  });

  it("makes a different key for each user action", () => {
    expect(newIdempotencyKey()).not.toBe(newIdempotencyKey());
  });

  it("sends the given key on each other entry write", async () => {
    api.defaults.adapter = scriptedAdapter([200, 200, 200, 200], sends);
    const keys = [1, 2, 3, 4].map(() => newIdempotencyKey());

    await timesheetEntryApi.update(7, { note: "edit" }, keys[0]);
    await timesheetEntryApi.destroy(7, keys[1]);
    await timesheetEntryApi.destroyBulk({ ids: [7, 8] }, keys[2]);
    await timesheetEntryApi.updateBulk({ ids: [7, 8] }, keys[3]);

    expect(sends.map(({ method, key }) => [method, key])).toEqual([
      ["put", keys[0]],
      ["delete", keys[1]],
      ["delete", keys[2]],
      ["patch", keys[3]],
    ]);
  });
});
