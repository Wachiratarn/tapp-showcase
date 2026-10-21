-- supabase/tests/10_break_autoclose.sql
-- Verifies the auto-close added in 20260801000001: when a time_entries row is
-- closed, any still-open break for it closes at GREATEST(clock_out_at,
-- break_start) — and is NOT rewritten to now() by the recursive trigger call.
BEGIN;
SELECT plan(5);

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('88888888-8888-8888-8888-888888888888', 'bc@bc.test',
        '{"signup_kind":"admin","company_name":"Co BC","full_name":"Admin BC"}');

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('99999999-9999-9999-9999-999999999999', 'emp-bc@bc.test',
        '{"signup_kind":"employee"}');

INSERT INTO profiles (id, company_id, role, full_name, email)
SELECT '99999999-9999-9999-9999-999999999999', company_id, 'employee', 'Emp BC', 'emp-bc@bc.test'
FROM profiles WHERE id = '88888888-8888-8888-8888-888888888888';

-- ---------------------------------------------------------------------------
-- Test 1 (LOAD-BEARING): employee clocks out with an open break.
-- break_end must equal the entry's clock_out_at, NOT now(). Before the session
-- flag, the recursive breaks-branch call rewrote this to now().
-- The employee path forces clock_out_at := now(), so both land on now() and we
-- must compare them to each other rather than to a literal.
-- ---------------------------------------------------------------------------
INSERT INTO time_entries (id, company_id, employee_id, worksite_address,
                          worksite_lat, worksite_lng, clock_in_at,
                          clock_in_lat, clock_in_lng)
SELECT 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1', company_id,
       '99999999-9999-9999-9999-999999999999', '1 St',
       40.7128, -74.0060, now() - interval '5 hours', 40.7128, -74.0060
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

INSERT INTO breaks (id, company_id, time_entry_id, break_start)
SELECT 'cccccccc-cccc-cccc-cccc-ccccccccccc1', company_id,
       'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1', now() - interval '2 hours'
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

UPDATE time_entries
   SET clock_out_at = now(), clock_out_lat = 40.7128, clock_out_lng = -74.0060
 WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1';

SELECT is(
  (SELECT break_end FROM breaks WHERE id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1'),
  (SELECT clock_out_at FROM time_entries WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1'),
  'Employee clock-out: break_end equals the entry clock_out_at exactly'
);

-- ---------------------------------------------------------------------------
-- Test 2: admin closes with a BACKDATED clock-out.
-- break_end must follow the backdated time, not now().
-- ---------------------------------------------------------------------------
INSERT INTO time_entries (id, company_id, employee_id, worksite_address,
                          worksite_lat, worksite_lng, clock_in_at,
                          clock_in_lat, clock_in_lng)
SELECT 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb2', company_id,
       '99999999-9999-9999-9999-999999999999', '2 St',
       40.7128, -74.0060, now() - interval '30 hours', 40.7128, -74.0060
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

INSERT INTO breaks (id, company_id, time_entry_id, break_start)
SELECT 'cccccccc-cccc-cccc-cccc-ccccccccccc2', company_id,
       'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb2', now() - interval '28 hours'
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

SET LOCAL "request.jwt.claims" TO '{"sub":"88888888-8888-8888-8888-888888888888","role":"authenticated"}';

UPDATE time_entries
   SET clock_out_at = now() - interval '24 hours',
       edited_by = '88888888-8888-8888-8888-888888888888',
       edit_reason = 'Forgot yesterday'
 WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb2';

SELECT ok(
  (SELECT break_end FROM breaks WHERE id = 'cccccccc-cccc-cccc-cccc-ccccccccccc2')
    < now() - interval '23 hours',
  'Admin backdated clock-out: break_end follows the backdated time, not now()'
);

-- ---------------------------------------------------------------------------
-- Test 3: admin backdates the clock-out to BEFORE break_start.
-- GREATEST clamps break_end to break_start → zero-length break, never negative.
-- ---------------------------------------------------------------------------
INSERT INTO time_entries (id, company_id, employee_id, worksite_address,
                          worksite_lat, worksite_lng, clock_in_at,
                          clock_in_lat, clock_in_lng)
SELECT 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb3', company_id,
       '99999999-9999-9999-9999-999999999999', '3 St',
       40.7128, -74.0060, now() - interval '10 hours', 40.7128, -74.0060
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

INSERT INTO breaks (id, company_id, time_entry_id, break_start)
SELECT 'cccccccc-cccc-cccc-cccc-ccccccccccc3', company_id,
       'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb3', now() - interval '4 hours'
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

UPDATE time_entries
   SET clock_out_at = now() - interval '6 hours',
       edited_by = '88888888-8888-8888-8888-888888888888',
       edit_reason = 'Left earlier than logged'
 WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb3';

SELECT is(
  (SELECT break_end - break_start FROM breaks
    WHERE id = 'cccccccc-cccc-cccc-cccc-ccccccccccc3'),
  interval '0',
  'Clock-out backdated before break_start: break clamped to zero length, not negative'
);

RESET "request.jwt.claims";

-- ---------------------------------------------------------------------------
-- Test 4: employee ends their OWN break normally → still rewritten to now().
-- The session flag must not leak and disable the employee path.
-- ---------------------------------------------------------------------------
INSERT INTO time_entries (id, company_id, employee_id, worksite_address,
                          worksite_lat, worksite_lng, clock_in_at,
                          clock_in_lat, clock_in_lng)
SELECT 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb4', company_id,
       '99999999-9999-9999-9999-999999999999', '4 St',
       40.7128, -74.0060, now() - interval '3 hours', 40.7128, -74.0060
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

INSERT INTO breaks (id, company_id, time_entry_id, break_start)
SELECT 'cccccccc-cccc-cccc-cccc-ccccccccccc4', company_id,
       'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb4', now() - interval '1 hour'
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

UPDATE breaks
   SET break_end = '2020-01-01 00:00:00+00'::timestamptz
 WHERE id = 'cccccccc-cccc-cccc-cccc-ccccccccccc4';

SELECT ok(
  (SELECT break_end FROM breaks WHERE id = 'cccccccc-cccc-cccc-cccc-ccccccccccc4')
    > now() - interval '1 minute',
  'Employee End Break: submitted 2020 value still discarded for server now()'
);

-- ---------------------------------------------------------------------------
-- Test 5: an UPDATE that does NOT close the entry leaves the open break alone.
-- Entry 4 is still open and its break was closed in Test 4, so open a fresh
-- break on it to prove a non-closing edit does not touch break_end.
-- ---------------------------------------------------------------------------
INSERT INTO breaks (id, company_id, time_entry_id, break_start)
SELECT 'cccccccc-cccc-cccc-cccc-ccccccccccc5', company_id,
       'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb4', now() - interval '10 minutes'
FROM profiles WHERE id = '99999999-9999-9999-9999-999999999999';

UPDATE time_entries
   SET worksite_address = '4 St (corrected)'
 WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb4';

SELECT is(
  (SELECT break_end FROM breaks WHERE id = 'cccccccc-cccc-cccc-cccc-ccccccccccc5'),
  NULL::timestamptz,
  'Non-closing entry UPDATE leaves an open break untouched'
);

SELECT * FROM finish();
ROLLBACK;
