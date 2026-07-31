import 'express';

/**
 * Express request augmentation.
 *
 * The RequestIdMiddleware stamps every request with `req.id`
 * (either an incoming X-Request-Id header or a generated UUID).
 */
declare global {
  namespace Express {
    interface Request {
      /** Unique identifier for the current request (string or numeric). */
      id?: string | number;
    }
  }
}

export {};
