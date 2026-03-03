---
name: backend
description: Backend implementation guide for APIs, database operations, auth, and business logic. Covers data validation, error handling, query optimization, and security. Use when building server-side features. Read project CLAUDE.md for framework-specific patterns.
user_invocable: true
---

# backend

Guide for implementing backend features. Framework-agnostic — read `CLAUDE.md` for project-specific patterns (ORM, auth provider, API style, database).

## Before Writing Code

1. Read `CLAUDE.md` for project-specific backend patterns and conventions
2. Check the database schema — understand existing tables and relationships
3. Identify the auth/authz pattern the project uses
4. Find existing endpoints/actions similar to what you're building — match patterns

## API Design

- Follow the project's existing API style (REST, GraphQL, RPC, server actions)
- Return consistent response shapes — match what other endpoints return
- Validate all input at the boundary — never trust client data
- Use appropriate error responses with useful messages

## Database Operations

### Queries
- Use parameterized queries — NEVER string interpolation for user input
- Select only the columns you need
- Add pagination for list endpoints (limit + offset or cursor-based)
- Use transactions for multi-step mutations
- Add indexes for new query patterns that filter or sort

### Migrations
- Make migrations reversible when possible
- Don't modify existing migration files — create new ones
- Add `NOT NULL` constraints with defaults for existing tables
- Consider impact on running applications (zero-downtime deploys)

## Authentication & Authorization

- Verify auth on EVERY server endpoint/action — don't assume middleware caught it
- Check authorization (does THIS user have permission for THIS resource?)
- Follow the project's auth pattern — don't introduce a new one
- Never expose internal IDs or other users' data in error messages
- Rate limit sensitive endpoints (login, password reset, API keys)

## Error Handling

- Catch errors at the boundary (route handler, action) — not deep in business logic
- Return user-friendly messages — don't leak stack traces or internal details
- Log the full error server-side for debugging
- Distinguish between client errors (bad input) and server errors (something broke)

## Data Validation

- Validate ALL external input at the system boundary
- Use the project's validation library (zod, joi, yup, etc.)
- Internal functions can trust their inputs — validate once at the edge
- Coerce types where appropriate (string IDs from URL params)
- Sanitize HTML/markdown input if it will be rendered

## Security Checklist

- [ ] No SQL injection (parameterized queries)
- [ ] No XSS (sanitized output)
- [ ] Auth checked on every endpoint
- [ ] Authorization checked (not just authentication)
- [ ] No secrets in code (use env vars)
- [ ] No sensitive data in logs
- [ ] Rate limiting on auth endpoints

## Testing

- Follow the project's test setup and patterns
- Test happy paths AND error paths
- Test auth: unauthenticated, unauthorized, authorized
- Test input validation: missing fields, wrong types, edge values
- Use the project's test database/fixtures approach

## Common Pitfalls

- Don't trust client input without validation — ever
- Don't put business logic in route handlers — extract to services/functions
- Don't make N+1 queries in loops — use joins or batch queries
- Don't store sensitive data unencrypted
- Don't return more data than the client needs
- Don't skip auth checks because "the UI doesn't show the button"
