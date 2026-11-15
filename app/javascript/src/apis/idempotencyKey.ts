// Decides which Idempotency-Key an entry write carries. The server stores
// only successful answers and refuses a reused key with a different body
// (422 idempotency_key_reused), so a key is reused only for an unchanged
// resend of the same action and is dropped once that action succeeds.
// Kept free of imports so it can be tested on its own.

export type ActionKey = {
  readonly key: string;
  readonly fingerprint: string;
};

// The entry gateway routes, relative to the API base URL. Only these keep
// receipts that an Idempotency-Key can replay.
const ENTRY_GATEWAY_PATH = /^\/timesheet_entry(\/|\?|$)/;
const STATE_CHANGING_METHODS: ReadonlySet<string> = new Set([
  "post",
  "put",
  "patch",
  "delete",
]);

const fingerprintOf = (body: unknown): string => JSON.stringify(body ?? null);

// The key for this send: the held key when the body is unchanged, so a resend
// replays the first answer; otherwise a fresh key, because an edited body is
// a new write.
export const keyForSend = (
  held: ActionKey | null,
  body: unknown,
  newKey: () => string
): ActionKey => {
  const fingerprint = fingerprintOf(body);
  if (held !== null && held.fingerprint === fingerprint) return held;

  return { key: newKey(), fingerprint };
};

// What the action holds after its answer: nothing after a success, so the
// next identical submit is written as a new entry; the same key after a
// failure or a lost answer, so an unchanged resubmit is a retry.
export const afterAnswer = (
  held: ActionKey | null,
  succeeded: boolean
): ActionKey | null => (succeeded ? null : held);

// Where one user action keeps its key between sends, such as a React ref.
export type HeldKey = { current: ActionKey | null };

// Runs one write of the action under its key. While the write is in flight
// nothing is held, so a second send started before it settles gets its own
// key even with an equal body: two distinct writes never share a receipt.
// Only this send's own outcome decides what is held afterwards: a success
// leaves nothing, and a failure puts this send's key back for an unchanged
// retry. The caller's write resolves only on a 2xx answer.
// A function declaration, because the build parses this file as TSX, where a
// generic arrow function's <T> reads as a JSX tag.
export async function sendWithHeldKey<T>(
  held: HeldKey,
  body: unknown,
  newKey: () => string,
  write: (idempotencyKey: string) => Promise<T>
): Promise<T> {
  const action = keyForSend(held.current, body, newKey);
  held.current = null;
  try {
    return await write(action.key);
  } catch (error) {
    held.current = afterAnswer(action, false);
    throw error;
  }
}

export const isEntryGatewayWrite = (method: string, url: string): boolean =>
  STATE_CHANGING_METHODS.has(method.toLowerCase()) &&
  ENTRY_GATEWAY_PATH.test(url);
