#!/bin/bash
# Reproducible re-run helper for the mock-web-eval demo (issue #232).
#
# Modes:
#   --dry-run            (default) runs pre-flight host checks and prints
#                        `dry-run: would …` markers for each downstream step
#                        without invoking compose or the classifier. Safe.
#   --full --pr <N>      Re-runs the classifier + dispatch end-to-end against
#                        an existing PR. Requires the operator setup from
#                        mock-web-eval/replay/README.md Section 2.
#
# Idempotent in --dry-run mode. See README.md for operator setup and
# pre-flight requirements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=true
FULL_MODE=false
PR_NUM=""

usage() {
  cat <<EOF
Usage: $0 [--dry-run | --full --pr <N>]

  --dry-run         (default) pre-flight checks + print downstream markers.
  --full --pr <N>   re-run classifier + dispatch against existing PR <N>.

See mock-web-eval/replay/README.md for operator setup.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      FULL_MODE=false
      shift
      ;;
    --full)
      DRY_RUN=false
      FULL_MODE=true
      shift
      ;;
    --pr)
      PR_NUM="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$FULL_MODE" = "true" ] && [ -z "$PR_NUM" ]; then
  echo "ERROR: --full requires --pr <N>" >&2
  exit 1
fi

cd "$REPO_ROOT"

# Step 1: source pipeline.config (warn in dry-run, fail in --full)
if [ ! -f pipeline.config ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "WARN: pipeline.config not found at repo root."
    echo "      See pipeline.config.example and mock-web-eval/replay/README.md Section 2."
    echo "      (dry-run continues; --full would abort here.)"
  else
    echo "ERROR: pipeline.config not found at repo root." >&2
    echo "       See pipeline.config.example and mock-web-eval/replay/README.md Section 2." >&2
    exit 1
  fi
else
  # shellcheck disable=SC1091
  source ./pipeline.config
fi

REQUIRED_VARS=(
  PIPELINE_EVAL_CLASSIFIER
  PIPELINE_EVAL_CONTAINERS
  PIPELINE_EVAL_CONTAINER_mock_web_eval_COMPOSE_FILE
  PIPELINE_EVAL_CONTAINER_mock_web_eval_SERVICE
  PIPELINE_EVAL_CONTAINER_mock_web_eval_ENV_FILE
  PIPELINE_EVAL_CONTAINER_mock_web_eval_PREFLIGHT_CMD
)
MISSING=()
for v in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!v:-}" ]; then
    MISSING+=("$v")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "WARN: pipeline.config missing required PIPELINE_EVAL_* vars: ${MISSING[*]}"
    echo "      See pipeline.config.example and mock-web-eval/replay/README.md Section 2."
    echo "      (dry-run continues; --full would abort here.)"
  else
    echo "ERROR: pipeline.config missing required PIPELINE_EVAL_* vars: ${MISSING[*]}" >&2
    echo "       See pipeline.config.example and mock-web-eval/replay/README.md Section 2." >&2
    exit 1
  fi
fi

# Step 2: host pre-flight checks (run in both modes; cheap)
preflight_warn() { echo "WARN: $1 (remediation: $2)"; }
preflight_fail() { echo "ERROR: $1 (remediation: $2)" >&2; exit 1; }

check_one() {
  local label="$1" remediation="$2" cmd="$3"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "preflight: $label OK"
  else
    if [ "$DRY_RUN" = "true" ]; then
      preflight_warn "$label" "$remediation"
    else
      preflight_fail "$label" "$remediation"
    fi
  fi
}

check_one "docker group membership" "add user to docker group: sudo usermod -aG docker \$USER" "groups | grep -qw docker"
check_one "claude credentials present" "log in via Claude Code or copy ~/.claude/.credentials.json" "[ -f \"\$HOME/.claude/.credentials.json\" ]"
check_one "gh auth status" "run: gh auth login" "gh auth status"
check_one "mock-web-eval classifier executable" "ensure mock-web-eval/scripts/mock-web-eval-classifier.sh exists and is +x" "[ -x \"$REPO_ROOT/mock-web-eval/scripts/mock-web-eval-classifier.sh\" ]"
echo "preflight: OK"

# Step 3: probe-port
if [ "$DRY_RUN" = "true" ]; then
  echo "dry-run: would run probe-port"
else
  bash "$REPO_ROOT/mock-web-eval/scripts/mock-web-eval-probe-port.sh"
fi

# Step 4: compose smoke
if [ "$DRY_RUN" = "true" ]; then
  echo "dry-run: would run compose smoke"
else
  if [ "$FULL_MODE" = "true" ]; then
    docker compose -f "$REPO_ROOT/mock-web-eval/docker/compose.yml" run --rm mock-web-eval claude --version
  fi
fi

# Step 5: classifier invocation
if [ "$DRY_RUN" = "true" ]; then
  echo "dry-run: would invoke classifier"
else
  if [ "$FULL_MODE" = "true" ]; then
    bash "$REPO_ROOT/mock-web-eval/scripts/eval-classifier-invoke.sh" "$PR_NUM"
  fi
fi

echo "replay: done (mode=$([ "$DRY_RUN" = "true" ] && echo dry-run || echo full))"
