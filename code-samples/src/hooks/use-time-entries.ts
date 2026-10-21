// src/hooks/use-time-entries.ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

export function useOpenTimeEntry(employeeId: string | undefined) {
  return useQuery({
    enabled: !!employeeId,
    queryKey: ['open-time-entry', employeeId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('time_entries').select('*')
        .eq('employee_id', employeeId!).is('clock_out_at', null)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });
}

export function useTimeEntryHistory(employeeId: string | undefined) {
  return useQuery({
    enabled: !!employeeId,
    queryKey: ['time-entry-history', employeeId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('time_entries')
        .select('*, breaks(break_start, break_end)')
        .eq('employee_id', employeeId!)
        .order('clock_in_at', { ascending: false })
        .limit(50);
      if (error) throw error;
      return data ?? [];
    },
  });
}

export function useClockIn() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      employee_id: string; company_id: string;
      worksite_address: string; worksite_lat: number; worksite_lng: number;
      clock_in_lat: number; clock_in_lng: number;
      address_note: string | null;
    }) => {
      const { data, error } = await supabase.from('time_entries').insert({
        ...input,
        // clock_in_at intentionally omitted — column DEFAULT now() fires server-side.
      }).select().single();
      if (error) throw error;
      return data;
    },
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ['open-time-entry', vars.employee_id] });
      qc.invalidateQueries({ queryKey: ['time-entry-history', vars.employee_id] });
      qc.invalidateQueries({ queryKey: ['recent-addresses', vars.employee_id] });
    },
  });
}

export function useClockOut() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      time_entry_id: string;
      employee_id: string;
      clock_out_lat: number; clock_out_lng: number;
    }) => {
      const { data, error } = await supabase.from('time_entries').update({
        clock_out_at: new Date().toISOString(),
        clock_out_lat: input.clock_out_lat,
        clock_out_lng: input.clock_out_lng,
      }).eq('id', input.time_entry_id).select().single();
      if (error) throw error;
      return data;
    },
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ['open-time-entry', vars.employee_id] });
      qc.invalidateQueries({ queryKey: ['time-entry-history', vars.employee_id] });
    },
  });
}
