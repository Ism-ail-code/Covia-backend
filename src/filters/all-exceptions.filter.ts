/**
 * AllExceptionsFilter — global error handler.
 *
 * Catches every exception that bubbles up and converts it into the
 * standardized API error response:
 *
 *   { success: false, message, errors, statusCode, path, timestamp, requestId }
 *
 * Handles:
 *   - HttpException (404, 403, validation errors, …)
 *   - Prisma errors (delegated mapping for known Prisma error codes)
 *   - Anything else → 500 Internal Server Error (details hidden in production)
 */

import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Prisma } from '../generated/prisma/client';
import type { Request, Response } from 'express';
import type { ApiErrorResponse } from '../types/api-response';

/** Error codes ≥ 500 never leak their internal details to clients. */
const INTERNAL_ERROR_THRESHOLD = 500;

/** Friendly messages for the most common Prisma error codes. */
const PRISMA_ERROR_MESSAGES: Record<string, string> = {
  P2002: 'A record with the same unique value already exists.',
  P2003: 'Related record not found.',
  P2025: 'The requested record was not found.',
};

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('Exceptions');

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request>();

    const statusCode = this.resolveStatusCode(exception);
    const { message, errors } = this.resolveMessage(exception, statusCode);

    if (statusCode >= INTERNAL_ERROR_THRESHOLD) {
      this.logger.error(
        `${request.method} ${request.originalUrl} → ${statusCode}: ${exception instanceof Error ? exception.stack : String(exception)}`,
      );
    } else {
      this.logger.warn(
        `${request.method} ${request.originalUrl} → ${statusCode}: ${message}`,
      );
    }

    const body: ApiErrorResponse = {
      success: false,
      message,
      errors,
      statusCode,
      path: request.originalUrl,
      timestamp: new Date().toISOString(),
      requestId:
        request.id == null
          ? undefined
          : (request.id as string | number).toString(),
    };

    response.status(statusCode).json(body);
  }

  private resolveStatusCode(exception: unknown): number {
    if (exception instanceof HttpException) return exception.getStatus();
    if (exception instanceof Prisma.PrismaClientKnownRequestError) {
      return PRISMA_ERROR_MESSAGES[exception.code]
        ? HttpStatus.CONFLICT
        : HttpStatus.BAD_REQUEST;
    }
    if (exception instanceof Prisma.PrismaClientValidationError)
      return HttpStatus.BAD_REQUEST;
    return HttpStatus.INTERNAL_SERVER_ERROR;
  }

  private resolveMessage(
    exception: unknown,
    statusCode: number,
  ): { message: string; errors?: unknown[] } {
    if (exception instanceof HttpException) {
      const response = exception.getResponse();
      if (typeof response === 'string') return { message: response };

      const { message, error } = response as {
        message?: unknown;
        error?: string;
      };
      if (Array.isArray(message)) {
        // class-validator sends an array of constraint messages.
        return { message: error ?? 'Validation failed', errors: message };
      }
      return {
        message: typeof message === 'string' ? message : 'Request failed',
      };
    }

    if (exception instanceof Prisma.PrismaClientKnownRequestError) {
      return {
        message:
          PRISMA_ERROR_MESSAGES[exception.code] ?? 'Database request failed.',
      };
    }

    return {
      message:
        statusCode >= INTERNAL_ERROR_THRESHOLD
          ? 'Internal server error'
          : 'Request failed',
    };
  }
}
