# Steps 6c / 6d — visual validation and the visual-proof loop

`skills/execute-issue-plan/SKILL.md` Steps 6c and 6d point here. Read it when
the diff touches UI, or when the issue carries the `needs-browser` label.
Backend-only changes skip both sub-steps; neither replaces 6a (type check) or
6b (tests), which always run.

**6c. Visual validation with Playwright** (Linux only, UI changes only): use Playwright MCP tools (configured in `.mcp.json`) to navigate to the frontend URL, screenshot affected views, and check `browser_console_messages` for JS errors. Fix and re-validate any visual issues. Backend-only changes do not require this step. (When clicking, prefer the `ref=` from `browser_snapshot` over CSS selectors with embedded quotes like `[type="submit"]` — the MCP server rejects the latter on the literal string; as of 2026-05-26.)

**6d. Visual proof loop (needs-browser issues only):** If the issue carries the needs-browser label, after each plan section invoke `Skill(skill: "pipeline:visual-proof-from-plan")` passing the plan comment body. Iterate code→proof→code per section until the sub-skill reports `unsatisfied = []`. Commit the section. Proceed to the next section. This is the executor-side TDD loop with browser predicates standing in for unit tests; it does NOT replace 6a/6b which still run.
