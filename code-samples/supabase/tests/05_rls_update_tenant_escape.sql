-- supabase/tests/05_rls_update_tenant_escape.sql

BEGIN;
SELECT plan(4);

-- Setup: two companies, each with one admin (creates the company via signup trigger)
-- and one employee added directly via the admin-set-up profile path.
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'admin-a@test',
   '{"signup_kind":"admin","company_name":"Tenant A","full_name":"Admin A"}'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'admin-b@test',
   '{"signup_kind":"admin","company_name":"Tenant B","full_name":"Admin B"}');

-- Pull the trigger-created company IDs and store for later
DO $$
DECLARE
  co_a uuid;
  co_b uuid;
BEGIN
  SELECT company_id INTO co_a FROM profiles
    WHERE id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT company_id INTO co_b FROM profiles
    WHERE id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  PERFORM set_config('test.co_a', co_a::text, false);
  PERFORM set_config('test.co_b', co_b::text, false);
END $$;

-- Add an employee to Co A
SET LOCAL ROLE postgres;
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'emp-a@test',
        '{"signup_kind":"employee"}');
INSERT INTO profiles (id, company_id, role, full_name, email)
VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc',
        current_setting('test.co_a')::uuid,
        'employee', 'Employee A', 'emp-a@test');

-- Insert an open time_entry for the employee, bypassing RLS as postgres
INSERT INTO time_entries (id, company_id, employee_id, worksite_address,
                          worksite_lat, worksite_lng,
                          clock_in_at, clock_in_lat, clock_in_lng, edited_by)
VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd',
        current_setting('test.co_a')::uuid,
        'cccccccc-cccc-cccc-cccc-cccccccccccc',
        '1 A St', 1, 1, now(), 1, 1,
        'cccccccc-cccc-cccc-cccc-cccccccccccc');

-- Insert an open break for that entry (also as postgres)
INSERT INTO breaks (id, company_id, time_entry_id, break_start)
VALUES ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
        current_setting('test.co_a')::uuid,
        'dddddddd-dddd-dddd-dddd-dddddddddddd',
        now());

-- Switch to the employee's auth context
SET LOCAL "request.jwt.claims" TO
  '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated"}';
SET LOCAL ROLE authenticated;

-- Test 1: employee cannot mutate company_id on time_entries (cross-tenant escape attempt)
-- WITH CHECK violations raise an error (not silently suppress), so we use throws_ok.
SELECT throws_ok($$
  UPDATE time_entries SET company_id = current_setting('test.co_b')::uuid
  WHERE id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
$$, NULL, NULL, 'Employee cannot UPDATE time_entries.company_id to another tenant');

-- Test 2: employee CAN clock out their own row (sanity — legitimate flow still works)
WITH upd AS (
  UPDATE time_entries
     SET clock_out_at = now(),
         clock_out_lat = 1, clock_out_lng = 1
   WHERE id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
  RETURNING 1
)
SELECT is((SELECT count(*)::int FROM upd), 1,
          'Employee can clock out their own open row');

-- Reset for break tests: re-open BOTH the time_entry and its break, as postgres.
--
-- The break must be re-opened too. Since 20260801000001, closing a time_entry
-- auto-closes any open break for it (the orphaned-break payroll fix), so Test 2's
-- clock-out above also set this break's break_end. Without re-opening it, Tests
-- 3-4 would run against an already-closed break: breaks_update_own_open requires
-- break_end IS NULL, so both would match 0 rows — Test 3 would report "no
-- exception" because RLS filtered the row out, not because the WITH CHECK
-- allowed the write. That is a false negative in a tenant-isolation test.
SET LOCAL ROLE postgres;
UPDATE time_entries
   SET clock_out_at = NULL, clock_out_lat = NULL, clock_out_lng = NULL
 WHERE id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
UPDATE breaks
   SET break_end = NULL
 WHERE id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
SET LOCAL "request.jwt.claims" TO
  '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated"}';
SET LOCAL ROLE authenticated;

-- Test 3: employee cannot mutate company_id on breaks
-- WITH CHECK violations raise an error (not silently suppress), so we use throws_ok.
SELECT throws_ok($$
  UPDATE breaks SET company_id = current_setting('test.co_b')::uuid
  WHERE id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
$$, NULL, NULL, 'Employee cannot UPDATE breaks.company_id to another tenant');

-- Test 4: employee CAN end their own break (sanity — legitimate flow)
WITH upd AS (
  UPDATE breaks SET break_end = now()
  WHERE id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
  RETURNING 1
)
SELECT is((SELECT count(*)::int FROM upd), 1,
          'Employee can end their own open break');

SELECT * FROM finish();
ROLLBACK;
