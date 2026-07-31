# Changelog

All notable changes to the Covia backend are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased]

### Phase 1 — Infrastructure (in progress)

- NestJS 11 application scaffolded with pnpm, strict TypeScript.
- Global request-id middleware (`X-Request-Id` / generated UUID, echoed on
  responses, logs, and envelopes).
- Global exception filter → standardized error envelope with friendly
  messages for common Prisma error codes (P2002, P2003, P2025).
- Global transform interceptor → standardized success envelope; pass-through
  for `success`-bearing payloads (enriched with traceability).
- Structured logging with pino (request correlation, redaction, pretty-print
  in development).
- Global validation pipe (whitelist + transform), Helmet, CORS from config,
  gzip compression, URI versioning (`/api/v1`), rate limiting.
- Boot-time environment validation (fails fast on missing/invalid config).
- Prisma 7 integration: `prisma-client` generator (commonjs module format),
  `@prisma/adapter-pg` driver adapter, config via `prisma.config.ts`,
  client regenerated on install.
- Global `PrismaService` with connection lifecycle hooks (global module).
- Embedded PostgreSQL development database (`scripts/dev-db.mjs`, port 5433,
  zero Docker/system install) + pnpm scripts for start/stop/migrate/studio.
- Health check endpoint `GET /api/v1/health` (server + database probe).
- Swagger/OpenAPI documentation at `/api/docs` (development only).
- Unit tests (Jest) and end-to-end tests (supertest against the real DB).
- Documentation: README, PROJECT_ARCHITECTURE, BACKEND_SETUP, src/ layout notes.
