/**
 * Covia Backend Validation — input validation helpers for API endpoints.
 */

/** Validate an email format. */
export function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
}

/** Validate a phone number format. */
export function isValidPhone(phone: string): boolean {
  const value = phone.trim();
  if (!/^\+?[()\d\s.-]{7,20}$/.test(value)) return false;
  const digits = value.replace(/\D/g, "");
  return digits.length >= 7 && digits.length <= 15;
}

/** Validate a username format (3-20 chars, lowercase alphanumeric + underscore). */
export function isValidUsername(username: string): boolean {
  return /^[a-z0-9_]{3,20}$/.test(username.trim().toLowerCase());
}

/** Validate a UUID format. */
export function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str);
}

/** Validate that a string is within length bounds. */
export function isLengthBetween(
  value: string,
  min: number,
  max: number,
): boolean {
  const len = value.trim().length;
  return len >= min && len <= max;
}

/** Validate that a number is within range. */
export function isInRange(
  value: number,
  min: number,
  max: number,
): boolean {
  return value >= min && value <= max;
}

/** Sanitize a string input by trimming and removing dangerous characters. */
export function sanitizeInput(input: string): string {
  return input
    .trim()
    .replace(/[<>]/g, "")
    .replace(/javascript:/gi, "")
    .replace(/on\w+=/gi, "");
}

/** Validate that a URL is safe (no javascript: protocol). */
export function isSafeUrl(url: string): boolean {
  const trimmed = url.trim().toLowerCase();
  if (trimmed.startsWith("javascript:")) return false;
  if (trimmed.startsWith("data:")) return false;
  if (trimmed.startsWith("vbscript:")) return false;
  return true;
}
