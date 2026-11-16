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

// The keys of an action's sends that failed or lost their answer, each kept
// for an unchanged retry, so several overlapping failed sends each keep
// their own key.
export type FailedKeys = readonly ActionKey[];

// The key for one send and the failed keys left once it is taken: the first
// failed key with an unchanged body, so the retry replays that send's answer,
// or a fresh key. A taken key leaves the list while its send is in flight,
// so a second send started before it settles gets its own key even with an
// equal body: two distinct writes never share a receipt.
export const takeKey = (
  failed: FailedKeys,
  body: unknown,
  newKey: () => string
): { action: ActionKey; failed: FailedKeys } => {
  const fingerprint = fingerprintOf(body);
  const index = failed.findIndex(held => held.fingerprint === fingerprint);
  const action = keyForSend(index === -1 ? null : failed[index], body, newKey);

  return { action, failed: failed.filter((_, at) => at !== index) };
};

// Where one user action keeps its failed keys between sends, such as a React ref.
export type HeldKeys = { current: FailedKeys };

// Runs one write of the action under its key. Only this send's own outcome
// decides what happens to its key: a success drops it, so the next identical
// submit is written as a new entry, and a failure puts it back for an
// unchanged retry. The caller's write resolves only on a 2xx answer.
// A function declaration, because the build parses this file as TSX, where a
// generic arrow function's <T> reads as a JSX tag.
export async function sendWithHeldKey<T>(
  held: HeldKeys,
  body: unknown,
  newKey: () => string,
  write: (idempotencyKey: string) => Promise<T>
): Promise<T> {
  const taken = takeKey(held.current, body, newKey);
  held.current = taken.failed;
  try {
    return await write(taken.action.key);
  } catch (error) {
    held.current = [...held.current, taken.action];
    throw error;
  }
}

export const isEntryGatewayWrite = (method: string, url: string): boolean =>
  STATE_CHANGING_METHODS.has(method.toLowerCase()) &&
  ENTRY_GATEWAY_PATH.test(url);
