//
// Per-employee and grand-total summary rows for the timesheet CSV.
//
// Summary rows are ordinary row objects carrying only the label and the
// numeric keys. toCsv() reads HEADERS positionally and renders a missing key
// as an empty field, so every emitted line has the full 13 fields without
// anyone counting commas by hand.
//
// Rows carry a hidden `_employee_id` used only for grouping. It is not in
// HEADERS, so it never reaches the file.
import type { CsvCell } from './csv.ts';

export type TimesheetRow = Record<string, CsvCell>;

export type Totals = {
  hours: number;
  breakHours: number;
  net: number;
  travel: number;
};

export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

// Blank for an OPEN row (hours_worked is '' when clock_out_at is null).
function num(v: CsvCell): number {
  return typeof v === 'number' ? v : 0;
}

// Sums the ALREADY-ROUNDED per-row values, so the printed sub-total equals
// what a reader gets adding the column with a calculator. round2 on the
// accumulator only removes float drift (0.1 + 0.2), never changes the figure.
export function sumRows(rows: TimesheetRow[]): Totals {
  const t = { hours: 0, breakHours: 0, net: 0, travel: 0 };
  for (const r of rows) {
    t.hours += num(r.hours_worked);
    t.breakHours += num(r.break_hours);
    t.net += num(r.net_site_hours);
    t.travel += num(r.travel_hours_after);
  }
  return {
    hours: round2(t.hours),
    breakHours: round2(t.breakHours),
    net: round2(t.net),
    travel: round2(t.travel),
  };
}

export function summaryBlock(totals: Totals, prefix = ''): TimesheetRow[] {
  return [
    {
      worksite_address: `${prefix}Sub-total`,
      hours_worked: totals.hours,
      break_hours: totals.breakHours,
      net_site_hours: totals.net,
      travel_hours_after: totals.travel,
    },
    {},
    { worksite_address: `${prefix}Total work hours`, hours_worked: totals.hours },
    {
      worksite_address: `${prefix}Total hours after break deduction (excl. travel)`,
      hours_worked: totals.net,
    },
    {
      worksite_address: `${prefix}Total hours after break deduction (incl. travel)`,
      hours_worked: round2(totals.net + totals.travel),
    },
    {},
  ];
}

// Expects rows already grouped by employee (the export sorts by name, which
// keeps each employee's rows contiguous and in clock-in order).
export function withSummaryRows(rows: TimesheetRow[]): TimesheetRow[] {
  if (rows.length === 0) return [];

  const out: TimesheetRow[] = [];
  let i = 0;
  while (i < rows.length) {
    const key = rows[i]._employee_id;
    const group: TimesheetRow[] = [];
    while (i < rows.length && rows[i]._employee_id === key) {
      group.push(rows[i]);
      i++;
    }
    out.push(...group, ...summaryBlock(sumRows(group)));
  }

  out.push(...summaryBlock(sumRows(rows), 'GRAND TOTAL — '));
  return out;
}
