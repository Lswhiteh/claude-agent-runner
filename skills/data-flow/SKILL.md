---
name: data-flow
description: Trace and validate data flow end-to-end through the stack — from database to API to UI. Identifies type mismatches, missing validation, broken contracts, and serialization issues. Use when debugging data issues or building features that touch multiple layers.
user_invocable: true
---

# data-flow

Trace data through the full stack to find and prevent issues at layer boundaries.

## When to Use

- Building a feature that touches DB → API → UI
- Debugging "data is wrong" or "undefined" issues
- After schema changes to verify nothing broke downstream
- Before finalizing a PR that changes data shapes

## The Layers

Trace data through each boundary:

```
Database Schema
    ↓ (query/ORM)
Server-Side Types (DB row types)
    ↓ (transformation)
API Response / Action Return
    ↓ (serialization — JSON boundary!)
Client-Side Types
    ↓ (state management)
Component Props
    ↓ (rendering)
UI Output
```

## Step 1: Start at the Database

Read the schema (migrations, ORM schema file, or DB dump). Document:
- Column names and types (especially nullable columns)
- Relationships (foreign keys, joins)
- Constraints (unique, check, not null)
- Default values

## Step 2: Check Query Layer

Read the query/ORM code that fetches this data:
- Are you selecting all needed columns?
- Are joins correct? (LEFT vs INNER — affects nullability)
- Are you handling the case where the query returns no rows?
- Does the ORM type match the actual query? (easy to drift)

## Step 3: Validate the Transformation Layer

This is where most bugs live. Check:
- Are dates converted correctly? (DB timestamp → language date type → string)
- Are enums mapped correctly? (DB string → type union)
- Are nullable fields handled? (`null` from DB vs `undefined` in code)
- Are IDs the right type? (string vs number — especially from URL params)
- Are nested objects shaped correctly? (join results → nested object)

## Step 4: Check the Serialization Boundary

JSON serialization loses information:
- Date objects become strings
- `undefined` fields are stripped (but `null` is preserved)
- BigInt, Map, Set, Infinity, NaN — all serialize incorrectly or throw
- Class instances lose their methods
- Functions cannot be serialized

Verify that the data shape after serialization matches what the consumer expects.

## Step 5: Verify Client-Side Types

- Do types match what the API actually returns?
- Are optional fields marked as optional?
- Is there validation at the boundary? (there should be)
- Are discriminated unions handled correctly?

## Step 6: Check Rendering

- Are loading/error/empty states handled?
- What renders when data is `null` or `undefined`?
- Are lists handled when empty? (`[]` vs `null` vs missing field)
- Are numbers/dates formatted for display?
- Is user-generated content sanitized before rendering?

## Common Data Flow Bugs

| Symptom | Likely Cause |
|---------|-------------|
| `undefined` in UI | Nullable DB column not handled, or field name mismatch |
| Wrong date/time | Timezone not handled at serialization boundary |
| "NaN" displayed | String ID used in arithmetic, or number field is null |
| Stale data after mutation | Missing cache invalidation |
| Type error at runtime | Type definition doesn't match actual API response |
| Empty list shows "No results" | API returns `null` instead of `[]` |

## Rules

- Always trace the ACTUAL data, not what the types SAY — add logging or breakpoints
- When types and runtime disagree, runtime is correct — fix the types
- Validate at every boundary crossing, not just the first one
- If you change a DB column, grep the entire codebase for that column name
