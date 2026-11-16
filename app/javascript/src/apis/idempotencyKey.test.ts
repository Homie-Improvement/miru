import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  entryTarget,
  type HeldKeys,
  isEntryGatewayWrite,
  keyForSend,
  sendWithHeldKey,
  takeKey,
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

describe("takeKey", () => {
  it("takes the failed key with an unchanged body out of the list", () => {
    const newKey = sequentialKeys();
    const failed = [
      keyForSend(null, entryBody(45), newKey),
      keyForSend(null, entryBody(60), newKey),
    ];

    const taken = takeKey(failed, entryBody(60), newKey);

    assert.equal(taken.action.key, "key-2");
    assert.deepEqual(taken.failed, [failed[0]]);
  });

  it("makes a fresh key and keeps the list when no failed body matches", () => {
    const newKey = sequentialKeys();
    const failed = [keyForSend(null, entryBody(45), newKey)];

    const taken = takeKey(failed, entryBody(60), newKey);

    assert.equal(taken.action.key, "key-2");
    assert.deepEqual(taken.failed, failed);
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
    const held: HeldKeys = { current: [] };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();

    const first = sendWithHeldKey(held, entryBody(60), newKey, write);
    const second = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers.forEach(settler => settler.resolve());
    await Promise.all([first, second]);

    assert.notEqual(sentKeys[0], sentKeys[1]);
  });

  it("keeps a failed send's key when an earlier send succeeds after it", async () => {
    const held: HeldKeys = { current: [] };
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
    const held: HeldKeys = { current: [] };
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
    assert.deepEqual(held.current, []);
  });

  it("retires a failed edit's key once a later edit of the same entry succeeds", async () => {
    const held: HeldKeys = { current: [] };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();
    const saveEdit = (duration: number) =>
      sendWithHeldKey(
        held,
        { entryId: 42, body: entryBody(duration) },
        newKey,
        write,
        entryTarget(42)
      );

    const lost = saveEdit(60);
    settlers[0].reject();
    await assert.rejects(lost);
    const later = saveEdit(90);
    settlers[1].resolve();
    await later;
    const newEdit = saveEdit(60);
    settlers[2].resolve();
    await newEdit;

    assert.notEqual(sentKeys[2], sentKeys[0]);
    assert.deepEqual(held.current, []);
  });

  it("keeps a failed edit's key when an edit of another entry succeeds", async () => {
    const held: HeldKeys = { current: [] };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();

    const saveEdit = (entryId: number) =>
      sendWithHeldKey(held, { entryId }, newKey, write, entryTarget(entryId));

    const lost = saveEdit(1);
    settlers[0].reject();
    await assert.rejects(lost);
    const other = saveEdit(2);
    settlers[1].resolve();
    await other;
    const retry = saveEdit(1);
    settlers[2].resolve();
    await retry;

    assert.equal(sentKeys[2], sentKeys[0]);
  });

  it("keeps each overlapping failed send's key, so retrying both replays both", async () => {
    const held: HeldKeys = { current: [] };
    const newKey = sequentialKeys();
    const { sentKeys, settlers, write } = pendingWrite();

    const first = sendWithHeldKey(held, entryBody(60), newKey, write);
    const second = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers[0].reject();
    await assert.rejects(first);
    settlers[1].reject();
    await assert.rejects(second);

    const firstRetry = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers[2].resolve();
    await firstRetry;
    const secondRetry = sendWithHeldKey(held, entryBody(60), newKey, write);
    settlers[3].resolve();
    await secondRetry;

    assert.deepEqual(
      [sentKeys[2], sentKeys[3]].sort(),
      [sentKeys[0], sentKeys[1]].sort()
    );
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
