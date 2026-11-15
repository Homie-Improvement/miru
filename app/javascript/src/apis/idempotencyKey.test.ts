import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  afterAnswer,
  isEntryGatewayWrite,
  keyForSend,
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
    assert.equal(isEntryGatewayWrite("post", "/timesheet_entries"), false);
  });
});
