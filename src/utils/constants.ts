/**
 * Covia Backend Constants — centralized server-side values.
 */

/** API response status codes. */
export const HTTP_STATUS = {
  OK: 200,
  CREATED: 201,
  NO_CONTENT: 204,
  BAD_REQUEST: 400,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  UNPROCESSABLE: 422,
  TOO_MANY_REQUESTS: 429,
  INTERNAL_ERROR: 500,
} as const;

/** Rate limiting defaults. */
export const RATE_LIMITS = {
  /** Auth endpoints: 5 requests per minute. */
  AUTH: { windowMs: 60_000, max: 5 },
  /** General API: 60 requests per minute. */
  API: { windowMs: 60_000, max: 60 },
  /** Search endpoints: 30 requests per minute. */
  SEARCH: { windowMs: 60_000, max: 30 },
  /** File upload: 10 requests per minute. */
  UPLOAD: { windowMs: 60_000, max: 10 },
} as const;

/** Pagination defaults. */
export const PAGINATION = {
  DEFAULT_PAGE: 1,
  DEFAULT_PAGE_SIZE: 20,
  MAX_PAGE_SIZE: 100,
} as const;

/** Storage bucket names. */
export const STORAGE_BUCKETS = {
  AVATARS: "avatars",
  VERIFICATION_DOCS: "verification-documents",
  FEEDBACK_SCREENSHOTS: "feedback-screenshots",
  RIDE_MEDIA: "ride-media",
} as const;

/** Allowed file extensions for uploads. */
export const ALLOWED_IMAGE_EXTENSIONS = ["jpg", "jpeg", "png", "gif", "webp"];
export const ALLOWED_DOC_EXTENSIONS = ["jpg", "jpeg", "png", "pdf"];
export const MAX_FILE_SIZE_MB = 10;

/** Ride constants. */
export const RIDE = {
  MIN_SEATS: 1,
  MAX_SEATS: 8,
  MIN_FARE: 0,
  MAX_FARE: 100_000,
  MAX_ROUTE_LENGTH: 500,
} as const;

/** Chat constants. */
export const CHAT = {
  MAX_MESSAGE_LENGTH: 500,
  MAX_MESSAGES_PER_PAGE: 50,
  MESSAGE_RETENTION_DAYS: 90,
} as const;

/** Safety constants. */
export const SAFETY = {
  SOS_COOLDOWN_MS: 60_000,
  CHECK_IN_MINUTES: 15,
  MAX_EMERGENCY_CONTACTS: 5,
  LOCATION_SHARING_MAX_HOURS: 24,
} as const;
