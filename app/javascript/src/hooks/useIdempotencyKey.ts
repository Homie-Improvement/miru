import { useCallback, useRef } from "react";

import { v4 as uuidv4 } from "uuid";

import { type FailedKeys, sendWithHeldKey } from "../apis/idempotencyKey";

interface UseIdempotencyKeyReturn {
  sendWithKey: <T extends object>(
    body: unknown,
    write: (idempotencyKey: string) => Promise<T>
  ) => Promise<T>;
}

// Holds the Idempotency-Keys for the user action a component owns, such as
// one entry form. A ref is used so that holding the keys never re-renders.
export const useIdempotencyKey = (): UseIdempotencyKeyReturn => {
  const held = useRef<FailedKeys>([]);

  const sendWithKey = useCallback(
    // The type parameter carries a constraint because the build parses this
    // file as TSX, where a bare <T> before an arrow reads as a JSX tag.
    <T extends object>(
      body: unknown,
      write: (idempotencyKey: string) => Promise<T>
    ): Promise<T> => sendWithHeldKey(held, body, uuidv4, write),
    []
  );

  return { sendWithKey };
};

export default useIdempotencyKey;
