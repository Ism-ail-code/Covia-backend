/**
 * Covia Backend Security — server-side security utilities.
 */

import { createHash, randomBytes } from "crypto";

/** Hash a string using SHA-256. */
export function hashString(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

/** Generate a random hex token. */
export function generateToken(length: number = 32): string {
  return randomBytes(length).toString("hex");
}

/** Generate a random alphanumeric code. */
export function generateCode(length: number = 6): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const bytes = randomBytes(length);
  let result = "";
  for (let i = 0; i < length; i++) {
    result += chars[bytes[i] % chars.length];
  }
  return result;
}

/** Mask an email for logging (safe for output). */
export function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  if (!local || !domain) return "***";
  if (local.length <= 2) return `${local[0]}***@${domain}`;
  return `${local[0]}${"*".repeat(Math.min(local.length - 2, 5))}@${domain}`;
}

/** Mask a phone number for logging. */
export function maskPhone(phone: string): string {
  const digits = phone.replace(/\D/g, "");
  if (digits.length < 7) return "***";
  const prefix = phone.startsWith("+") ? "+" : "";
  const first3 = digits.slice(0, 3);
  const last4 = digits.slice(-4);
  return `${prefix}${first3}***${last4}`;
}

/** Check if a string contains potential SQL injection patterns. */
export function hasSqlInjectionRisk(input: string): boolean {
  const patterns = [
    /(\b(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC|UNION|FETCH|DECLARE|TRUNCATE)\b)/i,
    /(--|;|\/\*|\*\/|xp_|sp_)/i,
    /(\b(OR|AND)\b\s+\d+\s*=\s*\d+)/i,
    /['"].*\b(OR|AND)\b.*['"]/i,
  ];
  return patterns.some((p) => p.test(input));
}

/** Sanitize a string for safe database logging. */
export function sanitizeForLog(input: string): string {
  return input
    .replace(/[\r\n]/g, " ")
    .replace(/\t/g, " ")
    .slice(0, 500);
}
