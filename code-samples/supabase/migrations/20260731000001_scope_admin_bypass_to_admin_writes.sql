-- supabase/migrations/20260731000001_scope_admin_bypass_to_admin_writes.sql
--
-- Fixes a critical hole opened by the admin clock-in feature.
--
-- THE MECHANISM (read this before touching either function again):
-- In Postgres, on an UPDATE the NEW record is populated from OLD for every
-- column NOT named in the SET list. The employee's clock-out
-- (src/hooks/use-time-entries.ts, useClockOut) sets only clock_out_at,
-- clock_out_lat, clock_out_lng. So when the row was CREATED by an admin
-- (admin clock-in writes edited_by = <admin uuid>), NEW.edited_by still
-- holds the admin's UUID during the EMPLOYEE's own UPDATE.
--
-- Both triggers below previously bypassed on `NEW.edited_by IS NOT NULL`.
-- That predicate was written when an OPEN row could never carry edited_by --
-- edited_by only appeared on admin edits, which always closed the row. Admin
-- clock-in created a row that is OPEN *and* already has edited_by set, so the
-- old predicate silently read as "an admin wrote this row once" when it was
-- meant to mean "an admin is writing right now". Result: on an employee's
-- clock-out of an admin-created entry, the server-side geofence check did not
-- run, AND the device-supplied clock_out_at was not rewritten to now() --
-- breaking two hard rules in CLAUDE.md ("Server-side geofence enforcement...
-- No exceptions" and "Never use device clock for clock_in_at / clock_out_at").
--
-- THE FIX: key the bypass on WHO IS WRITING, not on what the row happens to
-- hold. public.current_user_role() (20260428000001_initial_schema.sql) reads
-- the role of auth.uid(), the same helper the RLS policies use.
--
-- Why not `NEW.edited_by IS DISTINCT FROM OLD.edited_by`: that also fixes the
-- employee clock-out, but it reintroduces the bug that migration
-- 20260504000001 fixed, for a case this feature newly created. When the SAME
-- admin who created a row later closes it, use-edit-time-entry writes
-- edited_by = <same uuid>, so IS DISTINCT FROM is false, the bypass is lost,
-- and the admin's chosen past clock_out_at gets rewritten to now(). The actor
-- check has no such blind spot -- a same-value write by an admin is still an
-- admin write.
--
-- NULL SAFETY: when auth.uid() is NULL (service role, pg_cron, psql/pgTAP
-- with no JWT) current_user_role() returns NULL. `NULL = 'admin'` is NULL,
-- not true, so those writers fall through to ENFORCEMENT, never to bypass.
-- Never rewrite these as `IS DISTINCT FROM 'employee'` -- that would treat
-- NULL as permission and hand every service-role writer a free bypass.
--
-- pg_cron impact: the clock-out reminder job UPDATEs only reminder_sent_at on
-- OPEN entries. Both guarded blocks below additionally require the
-- clock_out_at NULL -> non-NULL transition, which that UPDATE never makes, so
-- both functions no-op on it regardless of the actor predicate.

-- enforce_geofence: BEFORE INSERT OR UPDATE on time_entries.
-- Predicate is now purely actor-based, and the edited_by test is gone.
--   INSERT by an admin  -> bypass. An admin-attested entry has no GPS reading;
--                          the payload mirrors the worksite coords.
--   INSERT by employee  -> enforced. Their own clock-in is still geofenced.
--   UPDATE by an admin  -> bypass. Admin edits carry no fresh GPS fix.
--   UPDATE by employee  -> enforced, INCLUDING on an admin-created row. This
--                          is the C1 fix.
-- Baseline: 20260528000001_company_geofence_radius.sql (per-company radius from
-- companies.geofence_radius_m). NOT the 20260428000003 version -- that one
-- called public.geofence_radius_m(), which 20260528000001 DROPPED. Everything
-- below except the bypass predicate is preserved verbatim from 20260528000001.
CREATE OR REPLACE FUNCTION public.enforce_geofence()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  d numeric;
  radius integer;
BEGIN
  -- Skip only when an admin is the one writing right now.
  -- NULL role (service role / cron / no JWT) is NOT admin and falls through.
  IF public.current_user_role() = 'admin' THEN
    RETURN NEW;
  END IF;

  SELECT geofence_radius_m INTO radius
  FROM companies WHERE id = NEW.company_id;

  IF radius IS NULL THEN
    RAISE EXCEPTION 'company % not found', NEW.company_id;
  END IF;

  IF TG_OP = 'INSERT' THEN
    d := public.haversine_meters(
      NEW.worksite_lat, NEW.worksite_lng,
      NEW.clock_in_lat, NEW.clock_in_lng
    );
    IF d > radius THEN
      RAISE EXCEPTION 'Clock-in location is %m from worksite (max: %m)',
        round(d), radius
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF TG_OP = 'UPDATE' AND NEW.clock_out_at IS NOT NULL AND OLD.clock_out_at IS NULL THEN
    d := public.haversine_meters(
      NEW.worksite_lat, NEW.worksite_lng,
      NEW.clock_out_lat, NEW.clock_out_lng
    );
    IF d > radius THEN
      RAISE EXCEPTION 'Clock-out location is %m from worksite (max: %m)',
        round(d), radius
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- force_server_close_timestamp: BEFORE UPDATE on time_entries, breaks,
-- invitations. Never fires on INSERT -- the INSERT side of the
-- server-timestamp rule is the clock_in_at column DEFAULT now()
-- (20260428000006_server_timestamps.sql), not this trigger.
--
-- The time_entries bypass is now actor-based for the same reason as above:
-- an admin closing a row to a past timestamp ("forgot yesterday at 5 PM")
-- must keep that timestamp, while an employee closing ANY row -- including
-- one an admin created -- must get server now().
--
-- The breaks and invitations branches are unchanged: neither table has an
-- edited_by column and neither has an admin-write path, so they always
-- force the server timestamp.
CREATE OR REPLACE FUNCTION public.force_server_close_timestamp()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME = 'time_entries' THEN
    -- Skip only when an admin is the one writing right now (mirrors
    -- enforce_geofence). NULL role is NOT admin and falls through to the
    -- rewrite, so service-role and cron writes stay server-stamped.
    IF public.current_user_role() = 'admin' THEN
      RETURN NEW;
    END IF;
    IF OLD.clock_out_at IS NULL AND NEW.clock_out_at IS NOT NULL THEN
      NEW.clock_out_at := now();
    END IF;
  ELSIF TG_TABLE_NAME = 'breaks' THEN
    IF OLD.break_end IS NULL AND NEW.break_end IS NOT NULL THEN
      NEW.break_end := now();
    END IF;
  ELSIF TG_TABLE_NAME = 'invitations' THEN
    IF OLD.accepted_at IS NULL AND NEW.accepted_at IS NOT NULL THEN
      NEW.accepted_at := now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
