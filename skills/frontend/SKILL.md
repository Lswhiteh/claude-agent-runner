---
name: frontend
description: Frontend implementation guide. Covers component structure, state management, data fetching, accessibility, and responsive design. Use when building or modifying UI. Read project CLAUDE.md for framework-specific patterns.
user_invocable: true
---

# frontend

Guide for implementing frontend features. Framework-agnostic — read `CLAUDE.md` for project-specific patterns (component library, styling, state management, routing).

## Before Writing Code

1. Read `CLAUDE.md` for project-specific UI patterns and conventions
2. Find 2-3 existing components similar to what you're building — match their patterns exactly
3. Check what UI primitives are available (component library, design system)
4. Identify the data source — how does this project fetch and pass data?

## Component Design

### Keep Components Focused
- One responsibility per component
- If a component file exceeds ~200 lines, consider splitting
- Separate data fetching from presentation where the framework supports it

### Props & State
- Prefer props over internal state — push state up to the nearest common ancestor
- URL state for anything filterable/shareable (tabs, filters, pagination, search)
- Local state only for transient UI (modals, hover, form-in-progress)
- Don't duplicate server state in client state — use the project's data fetching pattern

## Data Fetching

- Follow the project's established pattern — don't introduce a new one
- Handle all states: loading, error, empty, populated
- Show optimistic updates for mutations where appropriate
- Validate API response shapes at the boundary

## Styling

- Use whatever the project uses — don't introduce a new styling approach
- Mobile-first responsive design (test at 320px, 768px, 1024px, 1440px)
- Dark mode support if the project uses it
- Use existing design tokens / variables — don't hardcode colors or spacing
- Match existing spacing, typography, and color patterns

## Accessibility

- Semantic HTML: `button` not `div onClick`, `nav`, `main`, `section`
- All images need `alt` text (decorative images: `alt=""`)
- Form inputs need associated `label` elements
- Interactive elements need visible focus styles
- Keyboard navigation must work (tab order, escape to close modals)
- ARIA attributes only when semantic HTML isn't enough

## Testing

- Follow the project's test setup and patterns
- Test user-visible behavior, not implementation details
- Cover: happy path, error state, empty state, loading state
- Test interactions: clicks, form submissions, keyboard navigation

## Common Pitfalls

- Don't fetch data client-side when the framework supports server-side fetching
- Don't create wrapper components that just pass props through
- Don't add animation/transitions unless the design calls for it
- Don't ignore TypeScript errors — fix the types
- Don't duplicate logic between components — extract shared logic
