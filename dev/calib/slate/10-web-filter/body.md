## Context

The ledger view in `web/` shows every task in one table. With more than a
handful of tasks there is no way to find one without scrolling and reading
every title, and there is no way to send someone a link to "the release
tasks".

The CLI already answers "which tasks match this text"; the page should too.

## Scope

Add a title filter to the ledger view:

- add `<input id="filter" type="search" placeholder="filter by title">` above
  the table
- typing in the box filters the rows live: a row is shown when its **title**
  contains the box's text, case-insensitive substring
- a row that does not match is removed from the table or carries the `hidden`
  attribute (not a CSS class)
- a `?q=<term>` URL parameter pre-fills the box and applies the filter on load
- a `<p id="count">` reads `<shown> of <total> tasks`, kept up to date as the
  filter changes
- zero matches render a single `<tr id="empty">` whose one cell reads
  `no matching tasks`, mirroring the CLI; when nothing matches it is the only
  shown row in the table's `<tbody>`

An empty box shows every task, in id order, and the count reads
`6 of 6 tasks` for the shipped fixture.

## Affected areas

- `web/index.html` — the filter box and the count line
- `web/app.js` — the filtering, the `?q=` parameter, the count, the empty row
- `tests/case-web.sh` — extend with the `?q=` cases

The page loads its scripts with relative `<script src>` tags and no `fetch`, so
it keeps working when opened over `file://` as well as over HTTP.

## Notes

`web/tasks.js` stays untouched: the fixture is the data the page is checked
against. Out of scope: filtering by status or priority, and remembering the
filter between visits beyond the `?q=` parameter.
