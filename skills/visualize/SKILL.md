---
name: visualize
description: Render a document (`plan <file>`) or diff (`recap [git-range]`) as a single self-contained local HTML page (inline CSS/SVG/data-URIs, no CDN/fetch) and open it in the browser. Local render only. Usage: /pipeline:visualize plan <file> | recap [git-range] [--out <dir>]
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill, Write
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables (notably `PIPELINE_VISUALS_DIR` and `PIPELINE_BASE_BRANCH`) are available, then self-resolve `CLAUDE_PLUGIN_ROOT` in case the env var is unset in this Bash subshell:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The two config values this skill reads (`PIPELINE_VISUALS_DIR`, `PIPELINE_BASE_BRANCH`) each carry an inline default at their read site, so a project that never set them still works. `CLAUDE_PLUGIN_ROOT` is not required for the core render — this is a pure-prose skill with no helper scripts — but sourcing the config keeps behavior consistent with the sibling skills.

# Visualize

```
parse mode/args → (plan: read source | recap: distill diff) → load artifact-design → author ONE self-contained .html → print abs path FIRST → best-effort open
```

`/pipeline:visualize` turns a document or a diff into **one self-contained HTML page** you can open straight from `file://` — every byte inlined (CSS, SVG, data-URIs), zero CDN links, zero `fetch`. It is **local-render-only**: nothing is published, uploaded, or shared. This is a **pure-prose skill** — you (the model) do the authoring by hand; there are no helper scripts to call.

Two modes:

- **`plan <file>`** — a document (`md` / spec / report / `README` / any prose file) rendered as a visual plan.
- **`recap [git-range]`** — a diff rendered as a visual recap. You **distill** the change (stat + per-file notes + `git log --oneline`); you **never** paste a raw diff into the page.

## Step 1 — Parse the invocation

Read the invocation into: **mode** (`plan` or `recap`), the **positional arg** (a file path for `plan`; an optional git range for `recap`), and the **`--out <dir>`** flag if present.

- `plan` requires a `<file>` arg. If it is missing or the file does not exist, STOP and tell the operator the correct usage: `/pipeline:visualize plan <file>`.
- `recap` takes an **optional** git range. If absent, resolve the default range in Step 3.
- `--out <dir>` is optional in both modes and is consumed here (it is not the positional arg).

## Step 2 — Resolve the output directory

`--out <dir>` **wins with no prompt** — this keeps automated / scripted callers (which always pass `--out`) non-interactive.

Otherwise, **prompt the operator** — the write location varies run-to-run, so it is a real choice, not a default to assume:

```
where to write? [default: <resolved-knob>]
```

where `<resolved-knob>` is the value of the read site — literally:

```bash
${PIPELINE_VISUALS_DIR:-.claude/scratch/visuals/}
```

An empty reply accepts that default. The knob is a **commented** line in `pipeline.config.example` (defaults-in-code doctrine, #1052): the read site owns the default `.claude/scratch/visuals/`, `doctor --fix config` does not seed it, and it stays out of `tests/test-doctor-golden-seed-set.sh`. A project that wants a different fixed location uncomments and sets `PIPELINE_VISUALS_DIR` in its `pipeline.config`.

`mkdir -p` the resolved directory before writing.

**Output filename** = a slug of the source, with `.html` appended:

- `plan <file>` → slugify the source basename (drop the extension).
- `recap [range]` → slugify the range, or fall back to a timestamp slug (e.g. `recap-YYYYMMDD-HHMMSS`) when there is no explicit range.

Slug rule: lowercase, every non-alphanumeric run → a single `-`, collapse repeats, trim leading/trailing `-`. Final path = `<out-dir>/<slug>.html`.

## Step 3 — Gather the content

### plan mode
`Read` the source file in full. This is the substance the page will present. Identify its structure — headings, task lists, file lists, tables, code, open questions — so Step 4 can map each part onto the right block type.

### recap mode
Resolve the range, then **distill** (never dump):

1. **Resolve the base-branch-aware default range** (an explicit range arg always wins):
   - base = `PIPELINE_BASE_BRANCH` if set;
   - else the detected default branch: `git symbolic-ref --short refs/remotes/origin/HEAD` with the leading `origin/` stripped;
   - else `main`.
   - default range = `origin/<base>..HEAD`.
2. Collect, and turn each into prose/structured summary — **do not paste the raw unified diff**:
   - `git diff --stat <range>` → the file-level churn table (files, +/- counts).
   - Per-file **concise notes**: for each changed file, one or two lines on *what* changed and *why it matters* (you read the diff to write these; the page shows your distillation, not the hunks).
   - `git log --oneline <range>` → the commit list.

## Step 4 — Author the page

**Load the design discipline first**, then author exactly one `.html` file.

1. `Skill(skill: "artifact-design")` — read its palette / typography / layout guidance and let it drive the look. Calibrate the treatment to the subject: a plan or recap is a utilitarian document, so aim for polished and legible (real type hierarchy, considered spacing, a chosen neutral + one accent, both light and dark themes) rather than an over-designed hero.
2. Author **one self-contained `.html`** with the `Write` tool. **Self-contained invariant:** every byte is inlined — CSS in a `<style>` block, any imagery as inline SVG or `data:` URIs, fonts (if any) as `@font-face` data URIs. **No** external stylesheet/script/font links, **no** CDN, **no** `fetch`/XHR. The file must render correctly opened directly as `file://…` with no network.

**Block taxonomy** — draw from these; use the ones the content actually calls for, not all of them:

- **section / plan** — titled prose sections mirroring the document's headings.
- **file-tree map** — a tree of the files a plan touches or a recap changed.
- **comparison table** — before/after, option A/B, or trade-off matrices.
- **annotated-code** — a code snippet with callout annotations (used sparingly; not raw-diff dumping).
- **diff summary** — the recap's distilled `--stat` table + per-file notes (never the raw hunks).
- **data-model** — entities/fields/relations when the subject describes a schema.
- **wireframe** — a boxes-and-labels sketch when the subject describes UI.
- **callout** — highlighted notes, risks, warnings.
- **open-questions** — unresolved items pulled from the source.

Keep the page responsive (wide tables/code get their own `overflow-x:auto` container so the body never scrolls sideways) and theme-aware (style through CSS custom properties; give both `prefers-color-scheme` and the `data-theme` override the same care).

## Step 5 — Hand over the file

**Always print the absolute output path FIRST**, on its own, before attempting anything else — so a failed, skipped, or absent browser-open still hands the operator the file:

```
<abs-path-to-.html>
```

Then **best-effort open** the file in the local browser. This is a prose instruction, degrade-correctly by design (no runtime-handback coupling, YAGNI — no wrapper script):

- **Windows** → `Invoke-Item "<abs-path>"` (or `start "" "<abs-path>"`).
- **macOS** (`uname -s` = `Darwin`) → `open "<abs-path>"`.
- **Linux** with a display (`$DISPLAY` or `$WAYLAND_DISPLAY` set) → `xdg-open "<abs-path>"`.
- **Headless / any failure** (no display, missing opener, non-zero exit) → **skip silently**. The path was already printed; the operator opens it themselves.

Do not treat a failed open as a skill failure — the deliverable is the file, and the path is already in hand.

## Explicitly out of scope (do NOT add)

This skill is the **local render, and only the local render**. The following were deliberately dropped and must not be reintroduced:

- **`--share` / claude.ai Artifact publishing** — no upload, no hosted URL.
- **Classification / tier gate** — no sensitivity classification step.
- **Internal-tier-max logic** — no tier ceiling.

## Consumer migration (note)

A consumer that already ships its own local `visualize` skill should, after this lands, delete that local skill and repoint its `visualize` call sites to `/pipeline:visualize …` — passing an explicit `--out <dir>` wherever a fixed, backed-up location is wanted (which suppresses the prompt).
