# Covia Backend — Setup Guide

## Prerequisites

- **Node.js ≥ 20** (developed against 24)
- **pnpm ≥ 9** (`npm i -g pnpm`)
- No PostgreSQL or Docker required — the dev database is embedded.

## 1. Install dependencies

```bash
pnpm install
```

The install runs `prisma generate` (postinstall) to create the Prisma client
under `src/generated/prisma`. On pnpm 11, build scripts are gated by the
allowlist in `pnpm-workspace.yaml` — do not run with `--ignore-scripts`.

## 2. Configure environment

```bash
Copy-Item .env.example .env   # PowerShell
```

Adjust `DATABASE_URL` only if you change ports/credentials. The defaults match
the embedded database (port 5433, user `covia`, password `covia_dev_password`,
database `covia`).

## 3. Start the database

```bash
pnpm db:dev:start
```

First run downloads the PostgreSQL 18 binaries and initializes the cluster
under `.local/pg` (takes a couple of minutes; later starts are instant).
Keep this terminal open — the database stops when the script exits.
Stop it anytime with `pnpm db:dev:stop`.

## 4. Run the API

```bash
pnpm start:dev          # watch mode
```

Verify:

```bash
Invoke-RestMethod http://localhost:3000/api/v1/health
# success: true, status: OK, database: Connected, server: Running, version: 1.0.0
```

Swagger UI: http://localhost:3000/api/docs

## 5. Run tests

```bash
pnpm test               # unit
pnpm test:e2e           # e2e — requires the database to be running
```

## 6. Database changes (future phases)

```bash
pnpm exec prisma migrate dev --name <description>   # after editing schema.prisma
pnpm prisma:studio                                  # browse the data
```

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `PrismaClientInitializationError: driver adapter is required` | Run `pnpm prisma:generate`. |
| `ECONNREFUSED` on 5433 | Start the database first (`pnpm db:dev:start`). |
| `initdb: directory exists but is not empty` | Cluster was created; delete `.local/pg` only if you want to start fresh, then restart the DB. |
| Server exits at boot with validation error | Check `.env` — see error message for the missing key. |
| `EADDRINUSE` on 3000 | Another instance is running; stop it or change `PORT`. |

## Deploying (later)

Production runs `pnpm build` then `node dist/main.js` with a managed
PostgreSQL in `DATABASE_URL`, `NODE_ENV=production`, and `pnpm prisma:migrate:deploy`
as part of the release.
