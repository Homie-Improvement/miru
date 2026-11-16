import { timesheetEntryApi } from "apis/api";
import type { IdempotencyKey } from "apis/idempotency";
import { i18n } from "../../i18n";

export type TimerEntryPayload = {
  project_id: number;
  timesheet_entry: {
    work_date: string;
    duration: number;
    note: string;
    bill_status: "unbilled" | "non_billable";
  };
};

// Built once when the user saves a timer. React Query passes the same
// variables to every attempt, so a retry resends the same body and key and
// the server replays the first attempt's answer instead of writing twice.
export type SaveTimerVariables = {
  entry: TimerEntryPayload;
  userId?: string | number;
  idempotencyKey: IdempotencyKey;
};

export const saveTimerEntry = async ({
  entry,
  userId,
  idempotencyKey,
}: SaveTimerVariables) => {
  if (entry.timesheet_entry.duration < 1) {
    throw new Error(i18n.t("timer.durationAtLeastOneMinute"));
  }

  const response = await timesheetEntryApi.create(
    entry,
    idempotencyKey,
    userId
  );

  return response.data;
};
