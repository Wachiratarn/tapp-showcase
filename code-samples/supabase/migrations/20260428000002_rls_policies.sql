-- supabase/migrations/20260428000002_rls_policies.sql

-- Enable RLS on all tables
ALTER TABLE companies     ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE time_entries  ENABLE ROW LEVEL SECURITY;
ALTER TABLE breaks        ENABLE ROW LEVEL SECURITY;
ALTER TABLE invitations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_tokens   ENABLE ROW LEVEL SECURITY;

-- companies
CREATE POLICY companies_select_own ON companies
  FOR SELECT USING (id = public.current_company_id());
CREATE POLICY companies_update_admin ON companies
  FOR UPDATE USING (id = public.current_company_id() AND public.current_user_role() = 'admin')
  WITH CHECK (id = public.current_company_id() AND public.current_user_role() = 'admin');

-- profiles
CREATE POLICY profiles_select_same_company ON profiles
  FOR SELECT USING (company_id = public.current_company_id());
CREATE POLICY profiles_update_admin ON profiles
  FOR UPDATE USING (company_id = public.current_company_id() AND public.current_user_role() = 'admin')
  WITH CHECK (company_id = public.current_company_id() AND public.current_user_role() = 'admin');
-- Note: profiles INSERT is handled by signup trigger only (never by client).

-- time_entries
CREATE POLICY time_entries_select_same_company ON time_entries
  FOR SELECT USING (company_id = public.current_company_id());

CREATE POLICY time_entries_insert_self ON time_entries
  FOR INSERT WITH CHECK (
    company_id = public.current_company_id()
    AND employee_id = auth.uid()
  );

CREATE POLICY time_entries_update_own_open ON time_entries
  FOR UPDATE USING (
    employee_id = auth.uid()
    AND clock_out_at IS NULL
  )
  WITH CHECK (
    employee_id = auth.uid()
  );

CREATE POLICY time_entries_admin_all ON time_entries
  FOR ALL USING (
    company_id = public.current_company_id()
    AND public.current_user_role() = 'admin'
  )
  WITH CHECK (
    company_id = public.current_company_id()
    AND public.current_user_role() = 'admin'
  );

-- breaks
CREATE POLICY breaks_select_same_company ON breaks
  FOR SELECT USING (company_id = public.current_company_id());

CREATE POLICY breaks_insert_self ON breaks
  FOR INSERT WITH CHECK (
    company_id = public.current_company_id()
    AND EXISTS (
      SELECT 1 FROM time_entries te
      WHERE te.id = breaks.time_entry_id
        AND te.employee_id = auth.uid()
        AND te.clock_out_at IS NULL
    )
  );

CREATE POLICY breaks_update_own_open ON breaks
  FOR UPDATE USING (
    break_end IS NULL
    AND EXISTS (
      SELECT 1 FROM time_entries te
      WHERE te.id = breaks.time_entry_id AND te.employee_id = auth.uid()
    )
  );

CREATE POLICY breaks_admin_all ON breaks
  FOR ALL USING (
    company_id = public.current_company_id()
    AND public.current_user_role() = 'admin'
  )
  WITH CHECK (
    company_id = public.current_company_id()
    AND public.current_user_role() = 'admin'
  );

-- invitations (admin-only)
CREATE POLICY invitations_admin_all ON invitations
  FOR ALL USING (
    company_id = public.current_company_id()
    AND public.current_user_role() = 'admin'
  )
  WITH CHECK (
    company_id = public.current_company_id()
    AND public.current_user_role() = 'admin'
  );

-- push_tokens (each user manages own; admin can read same-company)
CREATE POLICY push_tokens_select_same_company ON push_tokens
  FOR SELECT USING (company_id = public.current_company_id());
CREATE POLICY push_tokens_insert_self ON push_tokens
  FOR INSERT WITH CHECK (profile_id = auth.uid());
CREATE POLICY push_tokens_update_self ON push_tokens
  FOR UPDATE USING (profile_id = auth.uid());
CREATE POLICY push_tokens_delete_self ON push_tokens
  FOR DELETE USING (profile_id = auth.uid());
