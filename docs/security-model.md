# Security model

## Trust boundary

The pipeline runs as slash-commands and hooks **inside the same OS user and
session as the agent**. An in-session agent has a shell with the operator's own
privileges. **Nothing the pipeline ships is a security boundary against that
shell** — a same-user process can express any intent in unbounded ways.

Treat every in-repo guard as a **best-effort tripwire**, not a wall.

## What the in-repo guards are (and aren't)

`hooks/restrict_paths.py`, `block_deletions.py`, `enforce-base-branch.py`, etc.
are **denylist tripwires**: they string-scan tool calls for a narrow set of
pipeline control files / dangerous ops and block the literal match.

Good for:
- **Accidents** — a fat-fingered edit to a guard file or `settings.json`. The
  common failure mode is a mistake; the denylist catches it cheaply.
- **Audit signal** — a *blocked* attempt is a loud "something went wrong" marker.
- **Defense-in-depth** behind a real sandbox.

NOT:
- A general dangerous-command firewall. `rm -rf`, `curl | bash`, force-push,
  exfiltration are **out of scope** — the scan never sees them.
- Sound against a determined same-user agent. Literal-substring scans fall to
  trivial shell idioms (var-indirection, glob, quote-split, `cd` + relative
  redirect — see #1069). Enumerating evasions is unwinnable; **we do not invest
  in closing them.**

## The real boundary (operator-owned)

Security comes from **confining capability**, not enumerating bad commands.
These levers live at the harness / OS layer and are the operator's to set — the
pipeline cannot impose them:

- **Permission mode** — allowlist specific commands; avoid bypass / allow-all.
- **Sandbox / container** — no network (or egress allowlist) kills `curl|bash`
  + exfiltration; **read-only mounts** for sensitive paths (guards, configs,
  `~/.ssh`, creds); **non-root user** + resource caps.
- **Least privilege** — short-lived, narrowly-scoped tokens; no ambient prod
  creds; no SSH-agent forwarding.
- **Human gate** on the irreversible / outward-facing class (deletes, pushes,
  sends).

The model: stop worrying *which* string the agent writes; make the dangerous
primitive **unreachable**, shrinking blast radius to near-zero.

## Division of responsibility

| Pipeline owns (cheap, shipped) | Operator owns (the boundary) |
|---|---|
| Best-effort tripwires (`restrict_paths.py`, `block_deletions.py`) | Permission mode (allowlist vs bypass) |
| Base-branch enforcement, path-C delegation guard | Sandbox / container, network egress, read-only mounts |
| Per-agent resource caps (`MemoryMax`/`TasksMax`, #918) | Non-root execution, token scope |
| Honest docs (this note) + doctor posture advisories | Human review of the session |

## Accepted residual risk

- **Dogfood self-hosting (#1068).** On the dogfood install the plugin-cache dir
  is a symlink to the working tree, so `realpath` resolves the running guard out
  of every protected pattern — an in-session agent can rewrite the live guard.
  **Accepted**: dogfood-only (real copied-cache consumers stay protected), and
  the naive fix (protect the guard's own dir) would block legitimate hook
  development in the repo that is its own substrate. The boundary for dogfooding
  is the operator's session posture, same as everywhere else.

## Where hardening IS worth it

Tightening an **allowlist** is the model that works, so over-broad *allow*
exemptions are worth fixing (unlike denylist evasions). Resolved: **#1070** —
`_worktree_pointer_allows` previously granted WRITE (incl. a git `pre-commit`
hook → code exec) into the main repo's per-worktree `.git` dir. Now the
per-worktree `hooks/` segment is denied before the trust-return block (anchored
exactly to `gitdir + "/hooks"` on the already-realpath'd path), killing the
code-exec vector while preserving the in-session recovery write-need (e.g.
`index.lock`, `HEAD`). Was confined to the operator's own tree (back-link
forgery into fresh OOB dirs is already blocked).
