# Covia backend source structure

```
src/
├── common/        Shared helpers used across modules (re-exports, mixins).
├── config/        Typed environment access + boot-time env validation.
├── database/      Global PrismaService (PostgreSQL connection lifecycle).
├── decorators/    Custom NestJS decorators (e.g. @CurrentUser — later phases).
├── filters/       Global exception filters → standardized error JSON.
├── guards/        Auth/authorization guards (added in later phases).
├── interceptors/  Response transformation, logging, caching.
├── middleware/    Request-level middleware (e.g. RequestIdMiddleware).
├── modules/       Feature modules — one folder per domain (health today).
├── services/      Long-lived domain services shared across modules.
├── types/         Shared TypeScript contracts (API responses, Express).
├── utils/         Pure helper functions (no NestJS dependencies).
└── generated/     Prisma client — GENERATED CODE, never edit or commit.
```

Rules of thumb:

- Feature code lives in `modules/<feature>/` with `controller`, `service`, `module`.
- Cross-cutting infrastructure goes in the top-level folders above.
- Controllers never touch `process.env` — use `ConfigService`.
- Controllers return plain payloads; the global `TransformInterceptor`
  wraps them into `{ success: true, data }`.
- Every route is versioned (`/api/v1/...`) — bump to `v2` for breaking changes.
