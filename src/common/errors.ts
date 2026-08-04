/**
 * Covia Backend Errors — custom error classes for structured error handling.
 */

/** Base application error. */
export class AppError extends Error {
  public readonly statusCode: number;
  public readonly code: string;

  constructor(message: string, statusCode: number = 500, code: string = "INTERNAL_ERROR") {
    super(message);
    this.name = "AppError";
    this.statusCode = statusCode;
    this.code = code;
  }
}

/** Bad request error (400). */
export class BadRequestError extends AppError {
  constructor(message: string = "Bad request") {
    super(message, 400, "BAD_REQUEST");
    this.name = "BadRequestError";
  }
}

/** Unauthorized error (401). */
export class UnauthorizedError extends AppError {
  constructor(message: string = "Unauthorized") {
    super(message, 401, "UNAUTHORIZED");
    this.name = "UnauthorizedError";
  }
}

/** Forbidden error (403). */
export class ForbiddenError extends AppError {
  constructor(message: string = "Forbidden") {
    super(message, 403, "FORBIDDEN");
    this.name = "ForbiddenError";
  }
}

/** Not found error (404). */
export class NotFoundError extends AppError {
  constructor(message: string = "Not found") {
    super(message, 404, "NOT_FOUND");
    this.name = "NotFoundError";
  }
}

/** Conflict error (409). */
export class ConflictError extends AppError {
  constructor(message: string = "Conflict") {
    super(message, 409, "CONFLICT");
    this.name = "ConflictError";
  }
}

/** Validation error (422). */
export class ValidationError extends AppError {
  public readonly fields?: Record<string, string>;

  constructor(message: string = "Validation failed", fields?: Record<string, string>) {
    super(message, 422, "VALIDATION_ERROR");
    this.name = "ValidationError";
    this.fields = fields;
  }
}

/** Rate limit error (429). */
export class RateLimitError extends AppError {
  constructor(message: string = "Too many requests") {
    super(message, 429, "RATE_LIMIT");
    this.name = "RateLimitError";
  }
}
