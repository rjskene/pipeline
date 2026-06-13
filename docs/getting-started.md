# Getting started on a greenfield project

This guide stands up claude-pipeline in a brand-new repository that never had the retired subtree installer. It is the greenfield counterpart to [migrating from a subtree install](migration-from-subtree.md): that guide retires a legacy `.claude-pipeline/` subtree install, this one bootstraps a fresh project from scratch.

This guide assumes the plugin is already installed (`/plugin install pipeline@claude-pipeline`). If it is not, install it first — see the README ["Install + first run"](../README.md#install--first-run) section.

## Bootstrap with `/pipeline:init`

From the root of your project, inside Claude Code:

```
/pipeline:init
```

`/pipeline:init` is the inverse of `migrate-from-subtree.sh` — migrate retires a legacy install, init creates a fresh one. It runs five phases:

1. **Preflight** — checks system dependencies (`gh`, `jq`, `bash` ≥4, `tmux`), printing the platform-appropriate install command if a hard dep is missing. It fails fast before writing any config.
2. **Config** — detects your repo and default branch (via `gh`), asks a small set of questions (base branch, test/typecheck/install commands, has-tests?, has-CI?), and writes `pipeline.config` with sane defaults for everything else. Projects without a test suite or CI get no-op defaults. It refuses to clobber an existing config without `--force`.
3. **Gitignore** — appends `pipeline.config` to `.gitignore` (it is host-specific; idempotent).
4. **Labels** — seeds the canonical GitHub labels.
5. **Doctor** — ends with a read-only `doctor` audit so init lands in a known state.

After init reports `bootstrap complete`, run `/pipeline:status` (formerly `/pipeline:run`, retained as a deprecated alias) to start the workflow.

### Staying current after a plugin update

After you `/plugin update` and `/reload-plugins`, the read-only doctor-on-update detector (`hooks/doctor-on-update.sh`) fires on your next prompt and directs the model to run the doctor reconcile for you — `/pipeline:doctor --fix config` (append any new `PIPELINE_*` knobs from `pipeline.config.example` into your host `pipeline.config`, never overwriting your values) plus `/pipeline:doctor --fix labels` (seed any new GitHub labels). It also names any new keys that still "need your value". Opt out with `PIPELINE_DOCTOR_ON_UPDATE_ENABLED="false"`. You can always run those two commands by hand. See [plugin-architecture.md](plugin-architecture.md) for the detector contract.

## Manual `pipeline.config` fallback

If you prefer to write `pipeline.config` by hand instead of running `/pipeline:init`, follow the manual-configuration steps in the README ["Install + first run"](../README.md#install--first-run) section, which lists the config keys and points to `pipeline.config.example` for the full set of options.
