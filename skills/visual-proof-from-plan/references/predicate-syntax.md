# Predicate syntax

A predicate is a JavaScript expression evaluated against the live DOM via
`mcp__playwright_*browser_evaluate`. The claim is considered **satisfied** when
the expression returns a truthy value, and **unsatisfied** when it returns a
falsy value or throws.

Predicates are declared in the `## Implementation Plan` comment, one per line,
prefixed with `predicate:` under an `**Acceptance criteria:**` or
`**Predicates:**` heading. For example:

```
**Acceptance criteria:**
predicate: document.querySelectorAll("#events-table tbody tr").length > 0
```

## querySelector predicates

Assert the presence (or absence) of an element matching a CSS selector.

```js
document.querySelector("#save-button") !== null
document.querySelector(".error-banner") === null
```

## Count predicates

Assert how many elements match a selector, using a comparison operator.
Supported operators: `>`, `>=`, `===`, `!==`.

```js
document.querySelectorAll("#events-table tbody tr").length > 0
document.querySelectorAll(".row").length >= 3
document.querySelectorAll("nav a").length === 5
document.querySelectorAll(".spinner").length !== 0
```

## Text predicates

Assert on the text content of an element using `textContent.includes(...)`.

```js
document.querySelector("h1").textContent.includes("Dashboard")
document.querySelector("#status").textContent.includes("Connected")
```

## URL precondition

A predicate may declare a navigation precondition: a URL to visit (resolved
against the consumer base URL, e.g. `APP_BASE_URL`) **before** the expression is
evaluated. Use the `after navigate to <path>` clause:

```
predicate: after navigate to /admin/events document.querySelectorAll("#events-table tbody tr").length > 0
```

The skill navigates to `<base>/admin/events`, then evaluates the trailing
expression. When no `after navigate to` clause is present, the predicate is
evaluated against the current page.
