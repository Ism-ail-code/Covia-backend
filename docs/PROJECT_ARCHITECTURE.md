# Covia Backend — Project Architecture

## 1. Overview

Covia is a social ride-coordination app: users post rides, join rides, and
communicate, while the actual vehicle is booked through a third-party
ride-hailing provider. The backend is a modular NestJS application whose Phase 1
delivers only the foundation — conventions, infrastructure, and a health
endpoint — so that future phases (auth, rides, chats, notifications) land on a
stable base.

## 2. Request lifecycle

```
Client
  │  HTTP
  ▼
Express (helmet → compression → CORS)
  │
  ▼
RequestIdMiddleware            assigns X-Request-Id / UUID → req.id
  │
  ▼
ThrottlerGuard (global)        rate limiting (per IP + key)
  │
  ▼
Controller (versioned /api/v1/*)
  │
  ▼
Service → PrismaService → PostgreSQL (pg adapter)
  │
  ▼
TransformInterceptor           wraps payload → success envelope
  │
  ▼
Client
```

Errors thrown anywhere are caught by `AllExceptionsFilter`:

- `HttpException` → its status/message (class-validator arrays become `errors`).
- Prisma `P2002`/`P2003`/`P2025` → 409/409/404 with friendly messages.
- Anything else → 500 "Internal server error" (details hidden; logged server-side).

## 3. Layer conventions

| Layer        | Rules |
| ------------ | ----- |
| **Controller** | Thin; route/versioning/swagger metadata; delegates to services; returns domain payloads. |
| **Service**    | Business logic; injects `PrismaService`/other services; never touches HTTP. |
| **DTO**        | class-validator decorators; created per endpoint in the feature folder. |
| **Module**     | One per feature under `src/modules/<feature>/`. |
| **Database**   | Single global `PrismaService`; features use `prisma.<model>` methods. |
| **Config**     | `ConfigService` only — never `process.env` in application code. |

## 4. Configuration & environment

Boot-time validation in `src/config/env.validation.ts` fails fast with a clear
message. Supported variables (see `.env.example`):

| Variable                 | Purpose                              |
| ------------------------ | ------------------------------------ |
| `NODE_ENV`               | development / production / test      |
| `PORT`                   | HTTP port (default 3000)             |
| `DATABASE_URL`           | PostgreSQL connection string         |
| `JWT_SECRET` / `JWT_REFRESH_SECRET` | Reserved for the auth phase  |
| `RATE_LIMIT_TTL` / `RATE_LIMIT_LIMIT` | Throttler window / max requests |
| `LOG_LEVEL`              | pino level                           |
| `CORS_ORIGINS`           | Comma-separated allowed origins      |
| `FILE_STORAGE_*`, `PUSH_*`, `MAPS_*`, `EMAIL_*` | Reserved for later phases |

## 5. Database & Prisma

- Prisma 7 `prisma-client` generator emits the client to `src/generated/prisma`
  (git-ignored, rebuilt on `pnpm install` via postinstall).
- The client requires a driver adapter; `PrismaService` wires `@prisma/adapter-pg`
  with the `DATABASE_URL` from config.
- `prisma.config.ts` holds CLI settings (schema/migrations paths + datasource
  URL) so Prisma CLI works without a `.env` loader.
- Schema has **no models yet** — the first migration is created together with
  the first feature phase.
- Local development uses `embedded-postgres` (see `scripts/dev-db.mjs`):
  zero Docker, zero system Postgres; cluster at `.local/pg`, port 5433.

## 6. Logging & observability

- pino via `nestjs-pino`; every request is logged with `req.id`, method, URL,
  status, and response time (automatic correlation with `X-Request-Id`).
- Dev mode uses `pino-pretty`; production logs structured JSON.
- Sensitive headers (authorization/cookie) are redacted by default.

## 7. Security baseline

- Helmet security headers; CORS restricted to configured origins.
- Global rate limiting (ThrottlerGuard) with per-key limits from env.
- Global validation pipe: `whitelist` (unknown props dropped),
  `transform` (DTO instances), implicit conversion disabled.
- Boot-time env validation rejects missing secrets.
- Swagger is exposed only outside `production`.

## 8. Versioning

URI versioning with default `v1`. Breaking changes add `v2` while `v1` stays
operational for the mobile clients in the wild.

## 9. Testing strategy

| Level | Tool    | Scope |
| ----- | ------- | ----- |
| Unit  | Jest    | Services/helpers with mocked providers (`*.spec.ts` next to code). |
| E2E   | Jest + supertest | Boots the full app against the real database (`test/*.e2e-spec.ts`), asserting envelopes, headers, versioning, and error shapes. |

E2E requires the embedded database to be running (`pnpm db:dev:start`).

## 10. Future phases (reserved infrastructure)

- `src/guards/` — JWT auth, roles
- `src/decorators/` — `@CurrentUser()`, `@Public()`, `@Roles()`
- `src/services/` — notifications, file storage, maps integration
- Integrations stubs already in `.env.example` (push, maps, email, storage)
