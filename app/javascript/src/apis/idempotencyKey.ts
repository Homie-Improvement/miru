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

// A failed send's key with the record it overwrites, such as "entry:42" for
// an edit or delete of entry 42, and the order the send started in. A create
// overwrites nothing, so its target is undefined.
export type FailedKey = ActionKey & {
  readonly target: string | undefined;
  readonly sequence: number;
};

// The keys of an action's sends that failed or lost their answer, each kept
// for an unchanged retry, so several overlapping failed sends each keep
// their own key.
export type FailedKeys = readonly FailedKey[];

// The target of an edit or delete of one entry.
export const entryTarget = (entryId: number | string): string =>
  `entry:${entryId}`;

// The target of a bulk move: a later successful move decides where the
// entries are, so it supersedes every earlier failed one from that screen.
export const BULK_MOVE_TARGET = "bulk-move";

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

// What one user action holds between sends. sends counts the sends started,
// so each send has an order. supersededBelow holds, per target, the order of
// the latest send that succeeded: a send to that target started before it is
// superseded, because the later write decides the record's state.
export type KeyState = {
  readonly failed: FailedKeys;
  readonly sends: number;
  readonly supersededBelow: ReadonlyMap<string, number>;
};

export const NO_HELD_KEYS: KeyState = {
  failed: [],
  sends: 0,
  supersededBelow: new Map(),
};

// One send in flight: its key, its order and the record it overwrites.
export type Send = {
  readonly action: ActionKey;
  readonly sequence: number;
  readonly target: string | undefined;
};

export const startSend = (
  state: KeyState,
  body: unknown,
  newKey: () => string,
  target: string | undefined
): { send: Send; state: KeyState } => {
  const taken = takeKey(state.failed, body, newKey);
  const sequence = state.sends + 1;

  return {
    send: { action: taken.action, sequence, target },
    state: { ...state, failed: taken.failed, sends: sequence },
  };
};

// The state once a send's answer arrives, in whatever order answers arrive.
// A success drops its key, so the next identical submit is a new write, and
// supersedes the failed sends to the same target that started before it:
// resending such a body is a new edit and must not replay the older answer
// over the newer state. A failure keeps the key for an unchanged retry,
// unless a later send to the same target already succeeded.
export const settleSend = (
  state: KeyState,
  send: Send,
  succeeded: boolean
): KeyState => {
  const { action, sequence, target } = send;
  const supersededBelow =
    target === undefined ? 0 : state.supersededBelow.get(target) ?? 0;

  if (!succeeded) {
    if (sequence < supersededBelow) return state;

    return {
      ...state,
      failed: [...state.failed, { ...action, target, sequence }],
    };
  }

  if (target === undefined || sequence <= supersededBelow) return state;

  return {
    ...state,
    failed: state.failed.filter(
      held => held.target !== target || held.sequence > sequence
    ),
    supersededBelow: new Map(state.supersededBelow).set(target, sequence),
  };
};

// Where one user action keeps its state between sends, such as a React ref.
export type HeldKeys = { current: KeyState };

// Runs one write of the action under its key, per startSend and settleSend.
// The caller's write resolves only on a 2xx answer.
// A function declaration, because the build parses this file as TSX, where a
// generic arrow function's <T> reads as a JSX tag.
export async function sendWithHeldKey<T>(
  held: HeldKeys,
  body: unknown,
  newKey: () => string,
  write: (idempotencyKey: string) => Promise<T>,
  target?: string
): Promise<T> {
  const started = startSend(held.current, body, newKey, target);
  held.current = started.state;
  let result: T;
  try {
    result = await write(started.send.action.key);
  } catch (error) {
    held.current = settleSend(held.current, started.send, false);
    throw error;
  }
  held.current = settleSend(held.current, started.send, true);

  return result;
}

export const isEntryGatewayWrite = (method: string, url: string): boolean =>
  STATE_CHANGING_METHODS.has(method.toLowerCase()) &&
  ENTRY_GATEWAY_PATH.test(url);
