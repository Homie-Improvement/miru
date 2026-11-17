import { timesheetEntryApi } from "apis/api";
import { newIdempotencyKey } from "apis/idempotency";

// Creates each entry in its own request under its own key. One key shared by
// several creates would make the server replay the first create's answer, or
// refuse the others as a reused key, so later entries would be lost.
export const createEntriesWithOwnKeys = (
  payloads: unknown[],
  userId?: string | number
) =>
  Promise.all(
    payloads.map(payload =>
      timesheetEntryApi.create(payload, newIdempotencyKey(), userId)
    )
  );
