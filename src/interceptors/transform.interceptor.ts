/**
 * TransformInterceptor — success envelope.
 *
 * Wraps every successful controller response as:
 *
 *   { success: true, message, data, path, timestamp, requestId }
 *
 * Convention: handlers that already return an object carrying a `success`
 * field (e.g. the health check) are passed through untouched.
 */

import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { Observable, map } from 'rxjs';
import type { ApiSuccessResponse } from '../types/api-response';

@Injectable()
export class TransformInterceptor<T> implements NestInterceptor<T, unknown> {
  intercept(
    context: ExecutionContext,
    next: CallHandler<T>,
  ): Observable<unknown> {
    const ctx = context.switchToHttp();
    const request = ctx.getRequest<{
      id?: string | number;
      originalUrl: string;
    }>();

    return next.handle().pipe(
      map((data) => {
        const requestId = request.id == null ? undefined : String(request.id);
        if (data && typeof data === 'object' && 'success' in data) {
          // Pass-through (e.g. health check): still enrich with traceability.
          return {
            ...data,
            requestId,
            path: request.originalUrl,
            timestamp: new Date().toISOString(),
          };
        }
        const envelope: ApiSuccessResponse<T> = {
          success: true,
          message: 'OK',
          data,
          path: request.originalUrl,
          timestamp: new Date().toISOString(),
          requestId,
        };
        return envelope;
      }),
    );
  }
}
