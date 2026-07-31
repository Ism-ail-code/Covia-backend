# guards/

Route guards enforce access rules before a handler runs.

Phase 1 does not implement authentication. Future phases will add:

- `JwtAuthGuard` — verifies the bearer access token (passport-jwt).
- `RefreshTokenGuard` — used by the refresh-token rotation endpoint.
- `RolesGuard` — role-based authorization for admin endpoints.

Global `ThrottlerGuard` (rate limiting) is already registered in `AppModule`.
