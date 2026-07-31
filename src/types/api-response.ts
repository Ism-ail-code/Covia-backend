/**
 * Standardized API response contracts.
 *
 * Every API response follows one of two shapes:
 *   - success: { success: true,  message, data, requestId, timestamp }
 *   - error:   { success: false, message, errors, statusCode, path, timestamp, requestId }
 *
 * Success responses are wrapped by the TransformInterceptor; errors are
 * produced by the global exception filters. Controllers only return their
 * domain payloads.
 */

export interface ApiSuccessResponse<T> {
  success: true;
  message: string;
  data: T;
  path: string;
  timestamp: string;
  requestId?: string;
}

export interface ApiErrorResponse {
  success: false;
  message: string;
  /** Field-level validation details (empty for non-validation errors). */
  errors?: unknown[];
  statusCode: number;
  path: string;
  timestamp: string;
  requestId?: string;
}

/** Health payload produced by HealthService (enriched by the interceptor). */
export interface HealthStatus {
  success: true;
  status: 'OK' | 'DEGRADED';
  database: 'Connected' | 'Disconnected';
  server: 'Running';
  version: string;
}

/** Health check response contract (GET /api/v1/health). */
export interface HealthResponse extends HealthStatus {
  path: string;
  timestamp: string;
  requestId?: string;
}
