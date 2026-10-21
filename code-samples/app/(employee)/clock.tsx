// app/(employee)/clock.tsx
import { useCallback, useRef, useState } from 'react';
import { View, Alert, ScrollView } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from 'expo-router';
import { useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../../src/hooks/use-auth';
import { useOpenTimeEntry, useTimeEntryHistory, useClockIn, useClockOut } from '../../src/hooks/use-time-entries';
import { useOpenBreak, useStartBreak, useEndBreak } from '../../src/hooks/use-breaks';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  getPushPermissionStatus,
  requestPushPermission,
  registerExpoPushToken,
} from '../../src/lib/push';
import { shouldPromptForPush } from '../../src/lib/push-prompt';
import { useRecentAddresses } from '../../src/hooks/use-recent-addresses';
import { ClockHeader } from '../../src/components/clock-screen/ClockHeader';
import { StatusPill } from '../../src/components/clock-screen/StatusPill';
import { LiveClock } from '../../src/components/clock-screen/LiveClock';
import { ClockButton } from '../../src/components/clock-screen/ClockButton';
import { ClockInSheet } from '../../src/components/clock-screen/ClockInSheet';
import { LastActionCard } from '../../src/components/clock-screen/LastActionCard';
import { ElapsedTime } from '../../src/components/clock-screen/ElapsedTime';
import { Button } from '../../src/components/ui/Button';
import { geocodeAddress, getCurrentPosition } from '../../src/lib/geocoding';
import { distanceMeters } from '../../src/lib/geofence';
import { useCompany } from '../../src/hooks/use-company';
import type { ClockInSheetRef } from '../../src/components/clock-screen/ClockInSheet';

// Set once we have shown the OS notification prompt on this device, so a user
// who dismisses it is not re-asked on every clock-in.
const PUSH_PROMPT_KEY = 'pushPromptShown';

export default function Clock() {
  const { profile } = useAuth();
  const { data: company } = useCompany(profile?.company_id);
  const qc = useQueryClient();
  const { data: openEntry } = useOpenTimeEntry(profile?.id);
  const { data: openBreak } = useOpenBreak(openEntry?.id);
  const { data: recents = [] } = useRecentAddresses(profile?.id);
  const { data: history = [] } = useTimeEntryHistory(profile?.id);
  const clockIn = useClockIn();
  const clockOut = useClockOut();
  const startBreak = useStartBreak();
  const endBreak = useEndBreak();
  const [busy, setBusy] = useState(false);
  const sheetRef = useRef<ClockInSheetRef>(null);

  // Force-refetch on every entry to this screen. Admin can clock the
  // employee out from the admin side, and without this the employee sees
  // a stale "clocked in" state until the app is killed. Bypasses the 30s
  // staleTime that refetchOnMount respects.
  useFocusEffect(
    useCallback(() => {
      if (!profile?.id) return;
      qc.invalidateQueries({ queryKey: ['open-time-entry', profile.id] });
      qc.invalidateQueries({ queryKey: ['time-entry-history', profile.id] });
    }, [qc, profile?.id]),
  );

  if (!profile || !company) return null;

  const state = openBreak ? 'onBreak' : openEntry ? 'clockedIn' : 'off';

  const lastClockOut =
    history.find((e) => e.clock_out_at != null)?.clock_out_at ?? null;

  // Clocks in with the address chosen in the location sheet. Returns true on
  // success so the sheet can close; false (or throws→false) keeps it open.
  const handleClockIn = async ({ address, note }: { address: string; note: string | null }): Promise<boolean> => {
    if (!address.trim()) { Alert.alert('Select a location first.'); return false; }
    setBusy(true);
    try {
      const geocoded = await geocodeAddress(address);
      if (!geocoded) { Alert.alert("Couldn't find this address. Check spelling and try again."); return false; }
      const pos = await getCurrentPosition();
      const d = distanceMeters(geocoded.lat, geocoded.lng, pos.lat, pos.lng);
      if (d > company.geofence_radius_m) {
        Alert.alert(`You're ${Math.round(d)}m from the address. Get within ${company.geofence_radius_m}m to clock in.`);
        return false;
      }
      await clockIn.mutateAsync({
        employee_id: profile.id, company_id: profile.company_id,
        worksite_address: geocoded.resolvedAddress,
        worksite_lat: geocoded.lat, worksite_lng: geocoded.lng,
        clock_in_lat: pos.lat, clock_in_lng: pos.lng,
        address_note: note,
      });
      // Ask for notification permission here, not at app launch: iOS allows the
      // system prompt exactly once per install, and just after a clock-in the
      // reason is self-evident. Deliberately not awaited before returning true —
      // the sheet should close on a successful clock-in regardless.
      void maybePromptForPush();
      return true;
    } catch (e) {
      Alert.alert(humanError((e as Error)?.message ?? String(e)));
      return false;
    } finally { setBusy(false); }
  };

  // Fires at most once per device. Failures are swallowed: a missing push
  // permission must never make a successful clock-in look broken.
  const maybePromptForPush = async () => {
    try {
      const asked = await AsyncStorage.getItem(PUSH_PROMPT_KEY);
      const status = await getPushPermissionStatus();
      if (!shouldPromptForPush(status, asked === 'true')) return;

      await AsyncStorage.setItem(PUSH_PROMPT_KEY, 'true');
      const next = await requestPushPermission();
      if (next === 'granted') {
        await registerExpoPushToken({
          profileId: profile.id,
          companyId: profile.company_id,
        });
      }
    } catch (e) {
      console.warn('Push permission prompt failed:', e);
    }
  };

  const handleClockOut = async () => {
    if (!openEntry) return;
    setBusy(true);
    try {
      const pos = await getCurrentPosition();
      const d = distanceMeters(
        Number(openEntry.worksite_lat), Number(openEntry.worksite_lng),
        pos.lat, pos.lng,
      );
      if (d > company.geofence_radius_m) {
        Alert.alert(`You're ${Math.round(d)}m from the worksite. Get within ${company.geofence_radius_m}m to clock out.`);
        return;
      }
      await clockOut.mutateAsync({
        time_entry_id: openEntry.id, employee_id: profile.id,
        clock_out_lat: pos.lat, clock_out_lng: pos.lng,
      });
    } catch (e) {
      Alert.alert(humanError((e as Error)?.message ?? String(e)));
    } finally { setBusy(false); }
  };

  const handleStartBreak = async () => {
    if (!openEntry) return;
    setBusy(true);
    try {
      await startBreak.mutateAsync({
        time_entry_id: openEntry.id, company_id: profile.company_id,
      });
    } catch (e) {
      Alert.alert(humanError((e as Error)?.message ?? String(e)));
    } finally { setBusy(false); }
  };

  const handleEndBreak = async () => {
    if (!openBreak || !openEntry) return;
    setBusy(true);
    try {
      await endBreak.mutateAsync({ break_id: openBreak.id, time_entry_id: openEntry.id });
    } catch (e) {
      Alert.alert(humanError((e as Error)?.message ?? String(e)));
    } finally { setBusy(false); }
  };

  const handleMainPress = () => {
    // Off → open the location sheet; clocking in happens on its Confirm.
    if (state === 'off') sheetRef.current?.open();
    else if (state === 'clockedIn') handleClockOut();
    else handleEndBreak();
  };

  return (
    <SafeAreaView edges={['top']} style={{ flex: 1, backgroundColor: '#ffffff' }}>
      <ClockHeader name={profile.full_name} />
      <ScrollView
        style={{ backgroundColor: '#f9f9ff' }}
        contentContainerStyle={{ flexGrow: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24, paddingVertical: 40, gap: 32 }}
        keyboardShouldPersistTaps="handled"
      >
        {/* Status + time block */}
        <View style={{ alignItems: 'center', gap: 16 }}>
          <StatusPill state={state} />
          <LiveClock />
        </View>

        {/* Central circular button */}
        <ClockButton
          state={state}
          onPress={handleMainPress}
          loading={busy || clockIn.isPending || clockOut.isPending || endBreak.isPending}
          address={state === 'clockedIn' ? (openEntry?.worksite_address ?? undefined) : undefined}
          clockInAt={state === 'clockedIn' ? (openEntry?.clock_in_at ?? undefined) : undefined}
        />

        {/* Break elapsed (below circle, only when onBreak) */}
        {state === 'onBreak' && openBreak && (
          <View style={{ alignItems: 'center', gap: 4 }}>
            <ElapsedTime since={openBreak.break_start} color="#3e494a" />
          </View>
        )}

        {/* Take a break button */}
        {state === 'clockedIn' && (
          <Button label="Take a break" variant="secondary" onPress={handleStartBreak} loading={startBreak.isPending} disabled={busy} />
        )}

        {/* Last Action card */}
        <View style={{ width: '100%', maxWidth: 360 }}>
          <LastActionCard lastClockOutAt={lastClockOut} />
        </View>
      </ScrollView>

      {/* Bottom sheet — rendered outside ScrollView so it overlays correctly */}
      <ClockInSheet
        ref={sheetRef}
        recents={recents}
        radiusMeters={company.geofence_radius_m}
        onConfirm={handleClockIn}
      />
    </SafeAreaView>
  );
}

function humanError(msg: string): string {
  if (msg === 'LOCATION_PERMISSION_DENIED') return 'Location access is required. Open Settings and allow location.';
  if (msg === 'GPS_TIMEOUT') return "Can't get your location. Try moving to an open area.";
  if (msg.includes('check_violation')) return 'Geofence rejected the action. Try moving closer to the address.';
  if (msg.includes('time_entries_one_open_per_employee')) return "You're already clocked in.";
  if (msg.includes('breaks_one_open_per_entry')) return "You're already on break.";
  return msg;
}
