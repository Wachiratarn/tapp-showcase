-- supabase/migrations/20260801000001_close_open_break_on_clock_out.sql
--
-- Fixes a payroll bug: closing a time_entries row while a breaks row for it is
-- still open orphaned that break. Nothing could ever close it — the employee's
-- app gates useOpenBreak on an open entry, and no admin UI edits breaks. The CSV
-- export skips breaks with a NULL break_end (`if (!b.break_end) continue;`), so
-- an orphaned break contributed ZERO minutes: break_hours read 0 and
-- net_site_hours equalled full hours_worked. The break was never deducted.
-- Reproduced on device 2026-07-31.
--
-- The break now closes at GREATEST(clock_out_at, break_start). Using the
-- (possibly backdated) clock_out_at rather than now() keeps admin corrections
-- sane; GREATEST clamps a clock-out backdated before break_start to a
-- zero-length break instead of a negative one.
--
-- WHY THIS LIVES INSIDE force_server_close_timestamp RATHER THAN IN ITS OWN
-- TRIGGER: the auto-close must read clock_out_at AFTER the employee-path rewrite
-- to now() has happened. A separate BEFORE trigger would depend on alphabetical
-- trigger-name ordering (the reason the existing triggers carry an `a_` prefix).
-- Folding it in removes that ordering dependency entirely.
--
-- WHY THE SESSION FLAG: a_breaks_force_server_close_ts fires on ANY breaks
-- UPDATE, so the UPDATE below re-enters this same function through its `breaks`
-- branch and would rewrite the computed break_end to now(). An actor-based
-- check does NOT work here — SECURITY DEFINER does not change auth.uid(), so an
-- employee's own clock-out evaluates as non-admin on the recursive call. The
-- exemption must key on THIS SPECIFIC WRITE, not on who is performing it.
-- set_config(..., true) is transaction-local and cannot leak past the statement.
--
-- SECURITY DEFINER + SET search_path are ADDED here (the function had neither).
-- The internal UPDATE below must write breaks rows the current actor may not own
-- under RLS breaks_update_own_open — an admin closing an employee's entry is
-- exactly that case. search_path is pinned because SECURITY DEFINER without it
-- is an injection vector. This widens the function's privilege; it applies to
-- all three trigger bindings, and the other two branches only ever assign to
-- NEW, so they gain nothing from it.
--
-- BASELINE: 20260731000001_scope_admin_bypass_to_admin_writes.sql (NOT the
-- 20260504000001 version — that one had a critical security hole fixed by
-- 20260731000001; do not rebuild from it).
--
-- NOTE: the admin bypass that was an early RETURN NEW in 20260504000001 is now a
-- nested IF. As an early return it would skip the auto-close on the admin path —
-- the exact path that orphans breaks.

CREATE OR REPLACE FUNCTION public.force_server_close_timestamp()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF TG_TABLE_NAME = 'time_entries' THEN
    -- Actor-based bypass, per 20260731000001. Admin edits keep their submitted
    -- timestamp; everyone else gets the server clock. IS DISTINCT FROM so a NULL
    -- role (service role, pg_cron, pgTAP with no JWT) is NOT treated as admin
    -- and falls through to the rewrite.
    IF public.current_user_role() IS DISTINCT FROM 'admin' THEN
      IF OLD.clock_out_at IS NULL AND NEW.clock_out_at IS NOT NULL THEN
        NEW.clock_out_at := now();
      END IF;
    END IF;

    -- Close any still-open break at the (now final) clock-out time.
    IF OLD.clock_out_at IS NULL AND NEW.clock_out_at IS NOT NULL THEN
      PERFORM set_config('app.closing_break_internally', 'on', true);
      UPDATE breaks
         SET break_end = GREATEST(NEW.clock_out_at, break_start)
       WHERE time_entry_id = NEW.id
         AND break_end IS NULL;
      PERFORM set_config('app.closing_break_internally', 'off', true);
    END IF;

  ELSIF TG_TABLE_NAME = 'breaks' THEN
    -- The auto-close above already computed the final value; do not rewrite it.
    -- missing_ok = true, else a session that never set the flag raises 42704.
    IF current_setting('app.closing_break_internally', true) = 'on' THEN
      RETURN NEW;
    END IF;
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
