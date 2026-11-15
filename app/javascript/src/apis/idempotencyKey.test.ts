import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  afterAnswer,
  type HeldKey,
  isEntryGatewayWrite,
  keyForSend,
  sendWithHeldKey,
} from "./idempotencyKey.ts";

const sequentialKeys = () => {
  let issued = 0;

  return () => `key-${++issued}`;
};

const entryBody = (duration: number) => ({
  project_id: 7,
  timesheet_entry: { work_date: "2025-01-06", duration, note: "Same" },
});

describe("keyForSend", () => {
  it("reuses the held key for an unchanged body", () => {
    const newKey = sequentialKeys();
    const held = keyForSend(null, entryBody(60), newKey);

    assert.equal(keyForSend(held, entryBody(60), newKey).key, held.key);
  });

  it("makes a new key when the body changed", () => {
    const newKey = sequentialKeys();
    const held = keyForSend(null, entryBody(60), newKey);

    assert.notEqual(keyForSend(held, entryBody(45), newKey).key, held.key);
  });

  it("makes a new key when nothing is held", () => {
    const newKey = sequentialKeys();

    assert.equal(keyForSend(null, entryBody(60), newKey).key, "key-1");
  });

  it("keeps different keys for two held values with equal bodies", () => {
    const newKey = sequentialKeys();
    const first = keyForSend(null, entryBody(60), newKey);
    const second = keyForSend(null, entryBody(60), newKey);

    assert.notEqual(first.key, second.key);
    assert.equal(keyForSend(first, entryBody(60), newKey).key, first.key);
    assert.equal(keyForSend(second, entryBody(60), newKey).key, second.key);
  });
});

describe("afterAnswer", () => {
  it("clears the held value after a success, so an identical next submit gets a new key", () => {
    const newKey = sequentialKeys();
    const held = keyForSend(null, entryBody(60), newKey);
    const cleared = afterAnswer(held, true);

    assert.equal(cleared, null);
    assert.notEqual(keyForSend(cleared, entryBody(60), newKey).key, held.key);
  });

  it("keeps the held value after a failure or a lost answer", () => {
    const newKey = sequentialKeys();
    const held = keyForSend(null, entryBody(60), newKey);
    const kept = afterAnswer(held, false);

    assert.equal(kept, held);
    assert.equal(keyForSend(kept, entryBody(60), newKey).key, held.key);
  });
});

// A write the test settles by hand, so two sends can overlap.
const pendingWrite = () => {
  const sentKeys: string[] = [];
  const settlers: Array<{ resolve: () => void; reject: () => void }> = [];
  const write = (idempotencyKey: string) =>
    new Promise<void>((resolve, reject) => {
      sentKeys.push(idempotencyKey);
      settlers.push({ resolve, reject: () => reject(new Error("lost")) });
    });

  return { sentKeys, settlers, write };
};

describe("sendWithHeldKey", () => {
  it("gives two equal sends in flight at once their own keys", async () => {
    const held: HeldKey = { current: null };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();

    const first = sendWithHeldKey(held, entryBody(60), newKey, write);
    const second = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers.forEach(settler => settler.resolve());
    await Promise.all([first, second]);

    assert.notEqual(sentKeys[0], sentKeys[1]);
  });

  it("keeps a failed send's key when an earlier send succeeds after it", async () => {
    const held: HeldKey = { current: null };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();

    const first = sendWithHeldKey(held, entryBody(60), newKey, write);
    const second = sendWithHeldKey(held, entryBody(45), newKey, write);
    settlers[1].reject();
    await assert.rejects(second);
    settlers[0].resolve();
    await first;

    const retry = sendWithHeldKey(held, entryBody(45), newKey, write);
    settlers[2].resolve();
    await retry;

    assert.equal(sentKeys[2], sentKeys[1]);
  });

  it("reuses the key for an unchanged retry after a failure and drops it after a success", async () => {
    const held: HeldKey = { current: null };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();

    const failed = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers[0].reject();
    await assert.rejects(failed);
    const retry = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers[1].resolve();
    await retry;
    const nextAction = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers[2].resolve();
    await nextAction;

    assert.equal(sentKeys[1], sentKeys[0]);
    assert.notEqual(sentKeys[2], sentKeys[0]);
    assert.equal(held.current, null);
  });
});

describe("isEntryGatewayWrite", () => {
  it("accepts every state-changing method on the entry routes", () => {
    for (const method of ["post", "PUT", "patch", "DELETE"]) {
      assert.equal(isEntryGatewayWrite(method, "/timesheet_entry"), true);
      assert.equal(isEntryGatewayWrite(method, "/timesheet_entry/42"), true);
      assert.equal(
        isEntryGatewayWrite(method, "/timesheet_entry/bulk_action/"),
        true
      );
    }

    assert.equal(
      isEntryGatewayWrite("post", "/timesheet_entry?user_id=5"),
      true
    );
  });

  it("rejects reads and other routes", () => {
    assert.equal(isEntryGatewayWrite("get", "/timesheet_entry"), false);
    assert.equal(isEntryGatewayWrite("get", "/timesheet_entry/42"), false);
    assert.equal(isEntryGatewayWrite("post", "/timeoff_entries"), false);
    assert.equal(isEntryGatewayWrite("put", "/timeoff_entries/3"), false);
    assert.equal(isEntryGatewayWrite("post", "/timesheet_entries"), false);
  });
});
