/**
 * Covia Backend Time — date/time utilities for server-side operations.
 */

/** Format a Date as ISO 8601 string. */
export function toISOString(date: Date): string {
  return date.toISOString();
}

/** Get the current timestamp as ISO string. */
export function now(): string {
  return new Date().toISOString();
}

/** Get a date N days ago. */
export function daysAgo(n: number): Date {
  const date = new Date();
  date.setDate(date.getDate() - n);
  return date;
}

/** Get a date N hours ago. */
export function hoursAgo(n: number): Date {
  const date = new Date();
  date.setHours(date.getHours() - n);
  return date;
}

/** Get a date N minutes ago. */
export function minutesAgo(n: number): Date {
  const date = new Date();
  date.setMinutes(date.getMinutes() - n);
  return date;
}

/** Check if a date is within the last N minutes. */
export function isWithinMinutes(date: Date, minutes: number): boolean {
  const cutoff = minutesAgo(minutes);
  return date >= cutoff;
}

/** Check if a date is within the last N hours. */
export function isWithinHours(date: Date, hours: number): boolean {
  const cutoff = hoursAgo(hours);
  return date >= cutoff;
}

/** Check if a date is within the last N days. */
export function isWithinDays(date: Date, days: number): boolean {
  const cutoff = daysAgo(days);
  return date >= cutoff;
}

/** Get the start of the day for a given date. */
export function startOfDay(date: Date = new Date()): Date {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  return d;
}

/** Get the end of the day for a given date. */
export function endOfDay(date: Date = new Date()): Date {
  const d = new Date(date);
  d.setHours(23, 59, 59, 999);
  return d;
}

/** Calculate the difference in milliseconds between two dates. */
export function diffMs(a: Date, b: Date): number {
  return a.getTime() - b.getTime();
}

/** Calculate the difference in minutes between two dates. */
export function diffMinutes(a: Date, b: Date): number {
  return Math.floor(diffMs(a, b) / 60_000);
}
