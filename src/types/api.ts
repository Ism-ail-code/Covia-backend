/**
 * Covia Backend API Types — shared API response and request types.
 */

/** Standard API success response. */
export type ApiResponse<T = unknown> = {
  success: true;
  data: T;
  meta?: {
    page?: number;
    pageSize?: number;
    total?: number;
    totalPages?: number;
  };
};

/** Standard API error response. */
export type ApiError = {
  success: false;
  error: {
    code: string;
    message: string;
    details?: Record<string, string>;
  };
};

/** Pagination query parameters. */
export type PaginationParams = {
  page?: number;
  pageSize?: number;
};

/** Sorting query parameters. */
export type SortParams = {
  sortBy?: string;
  sortDirection?: "asc" | "desc";
};

/** Search query parameters. */
export type SearchParams = PaginationParams &
  SortParams & {
    q?: string;
  };

/** Create a success response. */
export function successResponse<T>(data: T, meta?: ApiResponse<T>["meta"]): ApiResponse<T> {
  return { success: true, data, ...(meta ? { meta } : {}) };
}

/** Create an error response. */
export function errorResponse(code: string, message: string, details?: Record<string, string>): ApiError {
  return { success: false, error: { code, message, details } };
}
