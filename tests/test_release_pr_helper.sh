#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# pipeline.config is gitignored — prefer it locally, fall back to the
# committed pipeline.config.example so the test also runs in CI.
if [ -f ./pipeline.config ]; then
  # shellcheck disable=SC1091
  source ./pipeline.config
else
  # shellcheck disable=SC1091
  source ./pipeline.config.example
fi
export PIPELINE_REPO PIPELINE_RELEASE_PR_LABEL

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--label autorelease: pending"*"statusCheckRollup"*)
    cat <<'JSON'
[
  {"number":201,"title":"chore(main): release 1.2.3","headRefName":"release-please--branches--main","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
  {"number":202,"title":"chore(main): release 1.3.0","headRefName":"release-please--branches--main--components--x","statusCheckRollup":[{"conclusion":"FAILURE"}]},
  {"number":203,"title":"chore(main): release 2.0.0","headRefName":"release-please--branches--main--components--y","statusCheckRollup":[{"status":"IN_PROGRESS"}]}
]
JSON
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

OUT=$(PATH="$STUB_DIR:$PATH" bash scripts/list-release-prs.sh)
echo "$OUT" | grep -q '^pr=201 ci=pass title=' || { echo "FAIL: expected pass row for 201"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q '^pr=202 ci=fail title=' || { echo "FAIL: expected fail row for 202"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q '^pr=203 ci=pending title=' || { echo "FAIL: expected pending row for 203"; echo "$OUT"; exit 1; }
echo "PASS test_release_pr_helper"
