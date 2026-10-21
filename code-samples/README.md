# Code samples

A selection of files from Tapp's private repository, copied unedited with
their original paths. Each one was chosen to show one engineering concern from
end to end.

## Security: tenant isolation

| File | What to look at |
|---|---|
| [`supabase/migrations/20260428000002_rls_policies.sql`](supabase/migrations/20260428000002_rls_policies.sql) | Row-Level Security on every table. Each policy pairs the caller's company with their role, so isolation between companies is enforced by Postgres, not by app code. |
| [`supabase/tests/05_rls_update_tenant_escape.sql`](supabase/tests/05_rls_update_tenant_escape.sql) | pgTAP test that signs in as an employee and tries to move their own row into another company. Note the comment on re-opening the break: without it the test would pass for the wrong reason. |

## Integrity: geofence and server timestamps

| File | What to look at |
|---|---|
| [`supabase/migrations/20260731000001_scope_admin_bypass_to_admin_writes.sql`](supabase/migrations/20260731000001_scope_admin_bypass_to_admin_writes.sql) | The server-side geofence trigger, and the fix for a security hole a new feature opened. An admin bypass keyed on *what the row holds* let employees skip the check. The fix keys it on *who is writing*, and the header explains why the obvious alternative fails, including NULL-safety for service-role writes. |

## Payroll correctness: the orphaned-break bug

| File | What to look at |
|---|---|
| [`supabase/migrations/20260801000001_close_open_break_on_clock_out.sql`](supabase/migrations/20260801000001_close_open_break_on_clock_out.sql) | A break left open when a shift closed was never deducted from pay. The fix closes it inside the existing trigger, which re-enters itself, so it uses a transaction-scoped session flag. A role check can't tell the internal write apart from the employee's. |
| [`supabase/tests/10_break_autoclose.sql`](supabase/tests/10_break_autoclose.sql) | Tests for the fix, covering the re-entry case, backdated admin corrections, a clock-out before the break started (clamped to zero, never negative), and a check that the flag doesn't leak. |

## Backend: timesheet export

| File | What to look at |
|---|---|
| [`supabase/functions/export-timesheet/index.ts`](supabase/functions/export-timesheet/index.ts) | Deno Edge Function. Verifies the caller is an admin, queries through the caller's own JWT so RLS still applies, works out hours, breaks and travel time between sites, buckets dates by timezone, uploads the CSV and returns a signed URL that expires after an hour. |
| [`supabase/functions/_shared/timesheet-summary.ts`](supabase/functions/_shared/timesheet-summary.ts) | Pure functions for per-employee and grand-total rows. They add up the already-rounded figures, so the totals match what a payroll clerk gets with a calculator. |

## Mobile app: clock in and out

| File | What to look at |
|---|---|
| [`app/(employee)/clock.tsx`](app/%28employee%29/clock.tsx) | The main employee screen: a state machine (off, clocked in, on break), a client-side geofence check that gives a friendly error, database errors turned into plain-English messages, and the notification-permission prompt timed to iOS's one-prompt-per-install limit. |
| [`src/hooks/use-time-entries.ts`](src/hooks/use-time-entries.ts) | TanStack Query hooks. Clock-in leaves out `clock_in_at` so Postgres sets it, and the clock-out timestamp sent from the device is overwritten by the server trigger above. |
| [`src/lib/geofence.ts`](src/lib/geofence.ts) | The haversine distance check used for the client-side pre-check. The server runs the same check again in SQL. |

These files reference others that aren't included (shared helpers, UI
components, earlier migrations), so they won't build on their own. They're here
to be read.
