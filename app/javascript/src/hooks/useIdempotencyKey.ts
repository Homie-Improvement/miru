import { useCallback, useRef } from "react";

import { v4 as uuidv4 } from "uuid";

import {
  type ActionKey,
  afterAnswer,
  keyForSend,
} from "../apis/idempotencyKey";

interface UseIdempotencyKeyReturn {
  sendWithKey: <T extends object>(
    body: unknown,
    write: (idempotencyKey: string) => Promise<T>
  ) => Promise<T>;
}

// Holds one Idempotency-Key for the user action a component owns, such as
// one entry form. A ref is used so that holding the key never re-renders.
// Each component instance holds its own key, so two actions never share one.
export const useIdempotencyKey = (): UseIdempotencyKeyReturn => {
  const held = useRef<ActionKey | null>(null);

  // Runs one write under the held key and settles it by the outcome. The API
  // client resolves only 2xx answers and rejects every other answer and every
  // network error, so a resolved write is a success.
  const sendWithKey = useCallback(
    // The type parameter carries a constraint because the build parses this
    // file as TSX, where a bare <T> before an arrow reads as a JSX tag.
    async <T extends object>(
      body: unknown,
      write: (idempotencyKey: string) => Promise<T>
    ): Promise<T> => {
      const action = keyForSend(held.current, body, uuidv4);
      held.current = action;
      try {
        const result = await write(action.key);
        held.current = afterAnswer(held.current, true);

        return result;
      } catch (error) {
        held.current = afterAnswer(held.current, false);
        throw error;
      }
    },
    []
  );

  return { sendWithKey };
};

export default useIdempotencyKey;
