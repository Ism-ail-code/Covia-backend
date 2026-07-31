# decorators/

Custom decorators that enrich controllers with metadata or inject context.

Planned for future phases:

- `@CurrentUser()` — injects the authenticated user from the request.
- `@Public()` — marks routes that skip JWT authentication.
- `@Roles('admin')` — declares role requirements for a route.
