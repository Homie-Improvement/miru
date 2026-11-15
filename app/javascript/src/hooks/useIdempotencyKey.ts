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

  return { keyFor, settle };
};

export default useIdempotencyKey;
