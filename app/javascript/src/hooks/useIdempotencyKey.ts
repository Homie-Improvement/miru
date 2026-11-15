import { useCallback, useRef } from "react";

import { v4 as uuidv4 } from "uuid";

import {
  type ActionKey,
  afterAnswer,
  keyForSend,
} from "../apis/idempotencyKey";

interface UseIdempotencyKeyReturn {
  keyFor: (body: unknown) => string;
  settle: (succeeded: boolean) => void;
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

  const keyFor = useCallback((body: unknown): string => {
    held.current = keyForSend(held.current, body, uuidv4);

    return held.current.key;
  }, []);

  const settle = useCallback((succeeded: boolean): void => {
    held.current = afterAnswer(held.current, succeeded);
  }, []);

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
      const idempotencyKey = keyFor(body);
      try {
        const result = await write(idempotencyKey);
        settle(true);

        return result;
      } catch (error) {
        settle(false);
        throw error;
      }
    },
    [keyFor, settle]
  );

  return { keyFor, settle, sendWithKey };
};

export default useIdempotencyKey;
