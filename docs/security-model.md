# Security model

## Trust boundary

The pipeline runs as slash-commands and hooks **inside the same OS user and
session as the agent**. An in-session agent has a shell with the operator's own
privileges. **Nothing the pipeline ships is a security boundary against that
shell** — a same-user process can express any intent in unbounded ways.

Treat every in-repo guard as a **best-effort tripwire**, not a wall.

## What the in-repo guards are (and aren't)

The pipeline ships **no path-boundary or deletion guard hook** — #1418 retired
that class, so nothing it ships stands between an agent and a path or a delete.
What survives (`enforce-base-branch.py`, `enforce-path-c-delegation.py`,
`check-ci-skip-markers.py`, `enforce-ci-wait.py`, and `enforce-comment-trust.py`
on comment bytes) are **denylist tripwires over pipeline RULES a permission
classifier cannot know**: they string-scan tool calls for a narrow set of
pipeline control shapes and block the literal match.

Good for:
- **Accidents** — a PR opened off the wrong base, a CI-skip marker slipped into
  a commit. The common failure mode is a mistake; the denylist catches it cheaply.
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
  sends). For HEADLESS (`claude -p`) sessions the MECHANISM now ships, but read
  the LATENT caveat below before relying on it: every launcher runs the operator-owned
  permission mode (`--permission-mode auto --permission-prompts none`) with the
  `PermissionRequest` bridge (`hooks/permission-bridge.py`, issue #1421) as the
  escalation channel. An escalated call is queued for a human to answer; an
  unanswered one is DENIED, never granted. `--dangerously-skip-permissions` —
  which granted the whole irreversible class unseen — is no longer passed by any
  launcher (`PIPELINE_HEADLESS_PERMISSIONS=bypass` restores it for one run).
  Interactive sessions are unchanged: the bridge is inert without a queue dir.

  **The gate is LATENT under `auto` (measured, #1421).** The bridge itself is
  proven end-to-end: under `--permission-mode manual` an escalation queues, an
  `allow` round-trips the call, and an unanswered one is denied while the session
  still reaches a final message. But `--permission-mode auto` — what the
  launchers currently pass — escalates almost nothing. A probe confirmed that
  recursive force-deletes outside the workspace, hard resets that drop commits,
  untracked-file force-cleans, privilege escalation to root, outbound network
  fetches, and even an overwrite of the session settings file (the hook-disarm
  class) ALL ran with zero escalation and zero queue file. So today the bridge is
  a working rail carrying almost no traffic, and `bridge_prompts=` reads `0` on a
  typical run. Treat the headless human gate as SHIPPED-BUT-LATENT until the
  launchers move to `manual` / `default`. Read together with #1418 (which retired
  the path/deletion guard hooks), this is the accepted residual risk: under `auto`
  that class is guarded by nothing today, and moving the launchers off `auto` — not
  another tripwire — is what closes it.

The model: stop worrying *which* string the agent writes; make the dangerous
primitive **unreachable**, shrinking blast radius to near-zero.

## Division of responsibility

| Pipeline owns (cheap, shipped) | Operator owns (the boundary) |
|---|---|
| Best-effort tripwires over pipeline RULES only (base branch, PATH C delegation, CI-skip markers, CI wait, comment-byte trust) | The entire path/deletion class: auto mode's permission classifier plus the #1421 `PermissionRequest` bridge — no pipeline hook guards it (#1418) |
| Headless human gate: the `PermissionRequest` bridge (#1421) — queue the escalation, deny it unanswered. LATENT under `--permission-mode auto`, which escalates almost nothing (see above) | Choosing the permission mode (`auto` = few prompts, `manual` = a real gate), then actually watching the queue and answering it |
| Worktree isolation — execution happens off the main checkout | Sandbox / container, network egress, read-only mounts |
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
