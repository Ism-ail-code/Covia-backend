/**
 * RequestIdMiddleware
 *
 * Assigns a unique request id to every incoming request:
 *   - reuses an incoming `X-Request-Id` header when present (tracing),
 *   - otherwise generates a UUID.
 * The id is echoed on the `X-Request-Id` response header and carried into
 * logs, error responses and success envelopes for end-to-end traceability.
 */

import { Injectable, NestMiddleware } from '@nestjs/common';
import { randomUUID } from 'crypto';
import type { NextFunction, Request, Response } from 'express';

export const REQUEST_ID_HEADER = 'x-request-id';

@Injectable()
export class RequestIdMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction): void {
    const incoming = req.headers[REQUEST_ID_HEADER];
    const id = Array.isArray(incoming) ? incoming[0] : incoming;
    req.id = id ?? randomUUID();
    res.setHeader(REQUEST_ID_HEADER, req.id);
    next();
  }
}
