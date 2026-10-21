// supabase/functions/export-timesheet/index.ts
//
// Admin-only CSV export. Caller's JWT is verified, role checked, then the
// time_entries + breaks + profiles join is computed in TypeScript (hours
// worked, break minutes, net hours, implicit travel between same-day rows).
// CSV is uploaded via the service-role client to the `exports` bucket
// under <company_id>/<uuid>.csv and a 1-hour signed URL is returned.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
import { toCsv } from '../_shared/csv.ts';
import { round2, withSummaryRows } from '../_shared/timesheet-summary.ts';

type EntryRow = {
  id: string;
  employee_id: string;
  clock_in_at: string;
  clock_out_at: string | null;
  worksite_address: string;
  address_note: string | null;
  edited_by: string | null;
  edit_reason: string | null;
  profiles: { full_name: string; email: string } | null;
};

type BreakRow = {
  time_entry_id: string;
  break_start: string;
  break_end: string | null;
};

const HEADERS = [
  'employee_name',
  'employee_email',
  'date',
  'clock_in',
  'clock_out',
  'worksite_address',
  // The employee's own correction, when the device resolved the worksite to
  // the wrong address. Kept separate from `notes` (which carries an OPEN
  // marker and/or the admin's accumulated edit_reason, newline-separated)
  // so each column means exactly one thing.
  'address_note',
  'hours_worked',
  'break_hours',
  'net_site_hours',
  'travel_hours_after',
  'edited_by_admin',
  'notes',
] as const;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response('Unauthorized', { status: 401, headers: corsHeaders });
  }

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const {
    data: { user },
  } = await userClient.auth.getUser();
  if (!user) return new Response('Unauthorized', { status: 401, headers: corsHeaders });

  const { data: profile } = await userClient
    .from('profiles')
    .select('role, company_id')
    .eq('id', user.id)
    .single();
  if (profile?.role !== 'admin') {
    return new Response('Forbidden', { status: 403, headers: corsHeaders });
  }

  const body = (await req.json().catch(() => null)) as
    | { from?: string; to?: string; employee_ids?: string[]; timezone?: string }
    | null;
  const from = body?.from;
  const to = body?.to;
  if (!from || !to) {
    return new Response(
      JSON.stringify({ error: 'from and to required (ISO date)' }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
  const employee_ids = body?.employee_ids;

  const { data: company } = await adminClient
    .from('companies')
    .select('timezone')
    .eq('id', profile.company_id)
    .single();
  // Prefer the caller's device zone so the CSV matches what the admin sees in
  // the app (every screen renders with toLocaleTimeString(), i.e. device zone).
  // companies.timezone is the fallback for older clients that send nothing.
  // Validate before trusting it — an unknown zone makes Intl.DateTimeFormat
  // throw, which would 500 the whole export.
  function usableTimeZone(candidate: string | undefined): string | null {
    if (!candidate) return null;
    try {
      new Intl.DateTimeFormat('en', { timeZone: candidate });
      return candidate;
    } catch {
      return null;
    }
  }
  const tz = usableTimeZone(body?.timezone)
    ?? usableTimeZone(company?.timezone ?? undefined)
    ?? 'UTC';

  let entriesQ = userClient
    .from('time_entries')
    .select(
      'id, employee_id, clock_in_at, clock_out_at, worksite_address, address_note, edited_by, edit_reason, profiles!time_entries_employee_id_fkey(full_name, email)',
    )
    .gte('clock_in_at', from)
    .lt('clock_in_at', to)
    .order('employee_id')
    .order('clock_in_at');
  if (employee_ids && employee_ids.length) entriesQ = entriesQ.in('employee_id', employee_ids);

  const { data: entriesRaw, error: entriesErr } = await entriesQ;
  if (entriesErr) {
    return new Response(
      JSON.stringify({ error: entriesErr.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
  const entries = (entriesRaw ?? []) as unknown as EntryRow[];

  const ids = entries.map((e) => e.id);
  let breaks: BreakRow[] = [];
  if (ids.length) {
    const { data: breaksData, error: breaksErr } = await userClient
      .from('breaks')
      .select('time_entry_id, break_start, break_end')
      .in('time_entry_id', ids);
    if (breaksErr) {
      return new Response(
        JSON.stringify({ error: breaksErr.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }
    breaks = (breaksData ?? []) as BreakRow[];
  }

  const breakMinByEntry = new Map<string, number>();
  for (const b of breaks) {
    if (!b.break_end) continue;
    const m =
      (new Date(b.break_end).getTime() - new Date(b.break_start).getTime()) / 60000;
    breakMinByEntry.set(b.time_entry_id, (breakMinByEntry.get(b.time_entry_id) ?? 0) + m);
  }

  const dateFmt = new Intl.DateTimeFormat('en-CA', { timeZone: tz, dateStyle: 'short' });
  const timeFmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: tz,
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const localDate = (iso: string) => dateFmt.format(new Date(iso));
  const localTime = (iso: string) => timeFmt.format(new Date(iso));

  // Sort by name so each employee's rows are contiguous AND the per-employee
  // summary blocks appear in a readable order. Previously this sorted by
  // employee_id (a UUID), which is effectively random — invisible in a flat
  // list, obvious once the file has per-employee blocks. employee_id is the
  // tiebreak so two people sharing a name still group separately and the order
  // stays deterministic. The tiebreak must run whenever localeCompare returns
  // 0, not only when the strings are !==identical — ICU treats some distinct
  // strings (e.g. NFC vs NFD forms of the same name) as equal.
  const sorted = [...entries].sort((a, b) => {
    const an = a.profiles?.full_name ?? '';
    const bn = b.profiles?.full_name ?? '';
    const byName = an.localeCompare(bn);
    if (byName !== 0) return byName;
    if (a.employee_id !== b.employee_id) return a.employee_id < b.employee_id ? -1 : 1;
    return new Date(a.clock_in_at).getTime() - new Date(b.clock_in_at).getTime();
  });

  const rows = sorted.map((e, i) => {
    const next = sorted[i + 1];
    const sameEmpAndDay =
      next
      && next.employee_id === e.employee_id
      && localDate(next.clock_in_at) === localDate(e.clock_in_at);
    const travelHours = sameEmpAndDay && e.clock_out_at
      ? Math.max(
          0,
          round2(
            (new Date(next.clock_in_at).getTime() - new Date(e.clock_out_at).getTime()) / 3_600_000,
          ),
        )
      : 0;

    const hoursWorked = e.clock_out_at
      ? round2(
          (new Date(e.clock_out_at).getTime() - new Date(e.clock_in_at).getTime()) / 3_600_000,
        )
      : null;
    const breakMin = breakMinByEntry.get(e.id) ?? 0;
    const breakHours = round2(breakMin / 60);
    const netHours =
      hoursWorked != null ? Math.max(0, round2(hoursWorked - breakHours)) : null;

    return {
      // Grouping key for withSummaryRows. Not in HEADERS, so toCsv drops it.
      _employee_id: e.employee_id,
      employee_name: e.profiles?.full_name ?? '',
      employee_email: e.profiles?.email ?? '',
      date: localDate(e.clock_in_at),
      clock_in: localTime(e.clock_in_at),
      clock_out: e.clock_out_at ? localTime(e.clock_out_at) : '',
      worksite_address: e.worksite_address,
      address_note: e.address_note ?? '',
      hours_worked: hoursWorked ?? '',
      break_hours: breakHours,
      net_site_hours: netHours ?? '',
      travel_hours_after: travelHours,
      edited_by_admin: e.edited_by ? 'yes' : 'no',
      // An admin-created entry is born OPEN *and* carries an
      // [Admin clock-in] reason — the only provenance for an entry the
      // employee never made. Emit both; _shared/csv.ts quotes newlines.
      notes: [!e.clock_out_at ? 'OPEN' : null, e.edit_reason].filter(Boolean).join('\n'),
    };
  });

  // row_count must stay a count of DATA rows — the export screen reports it to
  // the admin, and counting label/blank lines would overstate what was exported.
  const dataRowCount = rows.length;
  const csv = toCsv([...HEADERS], withSummaryRows(rows));

  const uuid = crypto.randomUUID();
  const path = `${profile.company_id}/${uuid}.csv`;
  const { error: upErr } = await adminClient.storage
    .from('exports')
    .upload(path, new Blob([csv], { type: 'text/csv;charset=utf-8' }), {
      contentType: 'text/csv;charset=utf-8',
    });
  if (upErr) {
    return new Response(
      JSON.stringify({ error: upErr.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  const { data: signed, error: signErr } = await adminClient.storage
    .from('exports')
    .createSignedUrl(path, 60 * 60);
  if (signErr || !signed) {
    return new Response(
      JSON.stringify({ error: signErr?.message ?? 'sign failed' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  // Inside the edge container, SUPABASE_URL is `http://kong:8000` — the
  // signed URL the storage client returns is built off that internal host
  // and is not resolvable from a real device. PUBLIC_SUPABASE_URL (set in
  // supabase/.env for local dev; on hosted Supabase, omit it because
  // SUPABASE_URL is already the public HTTPS URL) lets us rewrite the
  // origin to something the client can reach.
  const publicUrl = Deno.env.get('PUBLIC_SUPABASE_URL');
  let signedUrl = signed.signedUrl;
  if (publicUrl) {
    try {
      const u = new URL(signedUrl);
      const p = new URL(publicUrl);
      u.protocol = p.protocol;
      u.host = p.host;
      signedUrl = u.toString();
    } catch {
      // Bad PUBLIC_SUPABASE_URL — fall through with the original signedUrl.
    }
  }

  return new Response(
    JSON.stringify({ url: signedUrl, row_count: dataRowCount }),
    { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});
