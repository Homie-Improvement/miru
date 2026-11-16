import { useCallback, useRef } from "react";

import { v4 as uuidv4 } from "uuid";

import {
  BULK_MOVE_TARGET,
  entryTarget,
  type KeyState,
  NO_HELD_KEYS,
  sendWithHeldKey,
} from "../apis/idempotencyKey";

export { BULK_MOVE_TARGET, entryTarget };

interface UseIdempotencyKeyReturn {
  sendWithKey: <T extends object>(
    body: unknown,
    write: (idempotencyKey: string) => Promise<T>,
    target?: string
  ) => Promise<T>;
}

// Holds the Idempotency-Keys for the user action a component owns, such as
// one entry form. A ref is used so that holding the keys never re-renders.
export const useIdempotencyKey = (): UseIdempotencyKeyReturn => {
  const held = useRef<KeyState>(NO_HELD_KEYS);

  const sendWithKey = useCallback(
    // The type parameter carries a constraint because the build parses this
    // file as TSX, where a bare <T> before an arrow reads as a JSX tag.
    <T extends object>(
      body: unknown,
      write: (idempotencyKey: string) => Promise<T>,
      target?: string
    ): Promise<T> => sendWithHeldKey(held, body, uuidv4, write, target),
    []
  );

  return { sendWithKey };
};

export default useIdempotencyKey;
