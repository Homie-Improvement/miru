import { v4 as uuidv4 } from "uuid";

export const IDEMPOTENCY_KEY_HEADER = "Idempotency-Key";

// The server replays a write whose key matches a stored success, so a key
// must be random: a predictable one could replay another action's answer.
// The brand keeps any other string, such as a user id, out of a key's place.
export type IdempotencyKey = string & { readonly __brand: "IdempotencyKey" };

// One key per user action. Make it when the action starts, outside anything
// a retry calls again, so every resend of that action carries the same key.
export const newIdempotencyKey = (): IdempotencyKey =>
  uuidv4() as IdempotencyKey;

// The header goes on the request's own config, not in the request
// interceptor, because the 401 recovery resends that config unchanged.
export const idempotencyHeaders = (key: IdempotencyKey) => ({
  [IDEMPOTENCY_KEY_HEADER]: key,
});
