/**
 * Covia Backend ID — ID generation and validation utilities.
 */

import { randomUUID } from "crypto";

/** Generate a new UUID v4. */
export function generateId(): string {
  return randomUUID();
}

/** Generate a short random ID (8 characters). */
export function generateShortId(): string {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  let result = "";
  const bytes = new Uint8Array(8);
  require("crypto").randomFillSync(bytes);
  for (let i = 0; i < 8; i++) {
    result += chars[bytes[i] % chars.length];
  }
  return result;
}

/** Validate that a string is a valid UUID. */
export function isValidId(id: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);
}

/** Validate that a string is a valid short ID. */
export function isValidShortId(id: string): boolean {
  return /^[a-z0-9]{8}$/.test(id);
}

/** Generate a prefixed ID (e.g., "fb_abc12345"). */
export function generatePrefixedId(prefix: string): string {
  return `${prefix}_${generateShortId()}`;
}
