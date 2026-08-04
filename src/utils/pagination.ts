/**
 * Covia Backend Pagination — pagination helpers for Supabase queries.
 */

import { PAGINATION } from "./constants";

export type PaginationResult<T> = {
  items: T[];
  total: number;
  page: number;
  pageSize: number;
  totalPages: number;
};

/** Calculate pagination parameters from query params. */
export function getPaginationParams(query: {
  page?: number | string;
  pageSize?: number | string;
}): { from: number; to: number; page: number; pageSize: number } {
  const page = Math.max(1, Number(query.page) || PAGINATION.DEFAULT_PAGE);
  const pageSize = Math.min(
    PAGINATION.MAX_PAGE_SIZE,
    Math.max(1, Number(query.pageSize) || PAGINATION.DEFAULT_PAGE_SIZE),
  );
  const from = (page - 1) * pageSize;
  const to = from + pageSize - 1;
  return { from, to, page, pageSize };
}

/** Build a pagination result from items and total count. */
export function buildPaginationResult<T>(
  items: T[],
  total: number,
  page: number,
  pageSize: number,
): PaginationResult<T> {
  return {
    items,
    total,
    page,
    pageSize,
    totalPages: Math.max(1, Math.ceil(total / pageSize)),
  };
}

/** Apply pagination to a Supabase query builder. */
export function applyPagination(
  query: any,
  from: number,
  to: number,
): any {
  return query.range(from, to);
}

/** Validate pagination parameters. */
export function validatePagination(page: number, pageSize: number): {
  valid: boolean;
  error?: string;
} {
  if (page < 1) return { valid: false, error: "Page must be at least 1." };
  if (pageSize < 1) return { valid: false, error: "Page size must be at least 1." };
  if (pageSize > PAGINATION.MAX_PAGE_SIZE) {
    return { valid: false, error: `Page size cannot exceed ${PAGINATION.MAX_PAGE_SIZE}.` };
  }
  return { valid: true };
}
