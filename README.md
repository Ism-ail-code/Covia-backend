# Covia Backend

Backend foundation for **Covia** — a mobile app that coordinates shared rides
booked through third-party ride-hailing services (Uber, Bolt, Careem, inDrive).

This repository currently contains **Phase 1: infrastructure only** plus the
**Phase 2 Supabase support** (auth schema + setup guide) and **Phase 3 user
profiles** (identity fields, username rules, public/private profile model,
avatar storage). No product features (rides, chats, payments) are implemented
yet; the architecture, tooling, and conventions below are in place to build
them on.

> Authentication and profiles for the mobile app run on **Supabase** (Auth +
> Postgres + Storage). This repo ships the schema (`supabase/migrations/`),
> a local SQL smoke test (`scripts/sql-smoke.mjs`) and the setup guide
> (`docs/SUPABASE_SETUP.md`). See `docs/DATABASE_SCHEMA.md` for the full
> schema reference. The NestJS API will serve business endpoints in later
> phases.

## Stack

| Layer       | Choice                                             |
| ----------- | -------------------------------------------------- |
| Language    | TypeScript (strict)                                |
| Framework   | NestJS 11                                          |
| ORM         | Prisma 7 (`prisma-client` generator + pg adapter)  |
| Database    | PostgreSQL 18 (embedded for local dev)             |
| Validation  | class-validator + class-transformer (global pipe)  |
| Logging     | pino via `nestjs-pino` (structured JSON)           |
| Docs        | Swagger / OpenAPI at `/api/docs` (dev only)        |
| Security    | Helmet, CORS, rate limiting, env validation        |
| Package mgr | pnpm 11                                            |

## Quick start

Prerequisites: Node.js ≥ 20, pnpm ≥ 9.

```bash
pnpm install

# 1. Start the embedded PostgreSQL (terminal 1)
pnpm db:dev:start

# 2. Start the API (terminal 2) — dev mode with watch
pnpm start:dev
```

Then:

- Health check: http://localhost:3000/api/v1/health
- Swagger docs: http://localhost:3000/api/docs

Stop the database with `pnpm db:dev:stop`.

### Environment

Copy `.env.example` to `.env` (already done locally; `.env` is git-ignored).
Required variables are validated at boot — the server refuses to start with
missing or invalid values.

## Scripts

| Script                  | Purpose                                        |
| ----------------------- | ---------------------------------------------- |
| `pnpm start:dev`        | Dev server with watch mode                     |
| `pnpm start:prod`       | Run the production build (`dist/main.js`)      |
| `pnpm build`            | Compile TypeScript to `dist/`                  |
| `pnpm typecheck`        | `tsc --noEmit`                                 |
| `pnpm lint`             | ESLint + Prettier (auto-fix)                   |
| `pnpm test`             | Unit tests (Jest)                              |
| `pnpm test:e2e`         | End-to-end tests against a real database       |
| `pnpm db:dev:start`     | Boot the embedded PostgreSQL (port 5433)       |
| `pnpm db:dev:stop`      | Stop the embedded PostgreSQL                   |
| `pnpm prisma:generate`  | Regenerate the Prisma client                   |
| `pnpm prisma:migrate`   | Create/apply dev migrations                    |
| `pnpm prisma:migrate:deploy` | Apply migrations without prompts        |
| `pnpm prisma:studio`    | Prisma Studio (database GUI)                   |

## API conventions

- All routes live under `/api/v1` (URI versioning; `v2` reserved for breaking changes).
- Responses are standardized:
  - Success: `{ success: true, message, data, path, timestamp, requestId }`
  - Error: `{ success: false, message, errors?, statusCode, path, timestamp, requestId }`
  - Health (`success`-bearing payloads) pass through, enriched with traceability.
- Every request gets an id (`X-Request-Id` header, or generated UUID) echoed on
  the response and carried through logs and envelopes.
- Controllers return plain domain payloads; the global `TransformInterceptor`
  wraps them. Errors are shaped by the global `AllExceptionsFilter` (known
  Prisma codes get friendly messages).
- Request bodies are validated globally — unknown properties are stripped
  (`whitelist`), values are transformed to DTO instances.

## Development database

No Docker and no system PostgreSQL are required. `embedded-postgres` manages a
local cluster under `.local/pg` (git-ignored) on port **5433** with a `covia`
role and a `covia` database. Production deployments will use a managed
PostgreSQL — the connection string is taken from `DATABASE_URL`.

Migrations are managed with `prisma migrate`; the first migration will be
created when the first application models are added.

The same embedded database doubles as a test bed for the Supabase SQL
migrations:

```bash
pnpm db:dev:start          # boot the database (terminal)
node scripts/sql-smoke.mjs # apply supabase/migrations/* to a scratch DB + assert
```

## Repository layout

```
src/
├── common/        Shared helpers used across modules
├── config/        Typed env access + boot-time validation
├── database/      Global PrismaService (pg driver adapter)
├── decorators/    Custom NestJS decorators (future phases)
├── filters/       Global exception filter → error envelope
├── guards/        Auth guards (future phases)
├── interceptors/  TransformInterceptor → success envelope
├── middleware/    RequestIdMiddleware
├── modules/       Feature modules (health today)
├── services/      Cross-cutting services (future phases)
├── types/         Shared TypeScript contracts
├── utils/         Pure helpers (future phases)
└── generated/     Prisma client — generated, git-ignored
```

See `docs/PROJECT_ARCHITECTURE.md` and `src/README.md` for details.
