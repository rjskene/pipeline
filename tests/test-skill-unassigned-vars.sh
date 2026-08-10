#!/bin/bash
set -uo pipefail

# #1215 — no skills/*/SKILL.md may reference an UNASSIGNED shell variable from
# inside an executable bash fence. Exemptions are deliberate contract changes,
# not workarounds: widening ENV_ALLOW or adding a `# Required env:` declaration
# is a claim that the caller supplies the value, and must be justified in review.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_ROOT="$REPO_ROOT/skills"
ENV_ALLOW="CLAUDE_PLUGIN_ROOT HOME PATH PWD USER SHELL TMPDIR IFS RANDOM"

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

scan() {
  awk -v allow="$ENV_ALLOW" '
    function is_fence_open(l) { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
    function is_fence_close(l){ return l ~ /^[[:space:]]*```[[:space:]]*$/ }
    BEGIN { n=split(allow,a," "); for(i=1;i<=n;i++) ok[a[i]]=1 }
    # ---- pass 1: harvest bindings from inside bash fences ----
    FNR==NR {
      if (is_fence_open($0)) { inb=1; next }
      if (is_fence_close($0)) { inb=0; next }
      if (!inb) next
      line=$0
      s=line
      while (match(s, /(^|[^A-Za-z0-9_$])[A-Z][A-Z0-9_]{2,}\+?=/)) {
        tok=substr(s,RSTART,RLENGTH); sub(/^[^A-Za-z0-9_]/,"",tok); sub(/\+?=$/,"",tok)
        bound[tok]=1; s=substr(s,RSTART+RLENGTH)
      }
      if (match(line,/(^|[^A-Za-z0-9_])read([[:space:]]+-[A-Za-z]+)*[[:space:]]/)) {
        rest=substr(line,RSTART+RLENGTH); sub(/[;|&<>#`$(].*$/,"",rest)
        nf=split(rest,w,/[^A-Za-z0-9_]+/)
        for(i=1;i<=nf;i++) if (w[i] ~ /^[A-Z][A-Z0-9_]{2,}$/) bound[w[i]]=1
      }
      if (match(line,/(^|[^A-Za-z0-9_])for[[:space:]]+[A-Z][A-Z0-9_]{2,}[[:space:]]/)) {
        t=substr(line,RSTART,RLENGTH); gsub(/[^A-Za-z0-9_]/," ",t); split(t,w," "); bound[w[2]]=1
      }
      if (match(line,/(^|[^A-Za-z0-9_])(mapfile|readarray)([[:space:]]+-[A-Za-z]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+[A-Z][A-Z0-9_]{2,}/)) {
        t=substr(line,RSTART,RLENGTH); nf=split(t,w,/[[:space:]]+/)
        for(i=1;i<=nf;i++) if (w[i] ~ /^[A-Z][A-Z0-9_]{2,}$/) bound[w[i]]=1
      }
      if (match(line,/(^|[^A-Za-z0-9_])(local|declare|typeset)[[:space:]]+[A-Z][A-Z0-9_]{2,}/)) {
        t=substr(line,RSTART,RLENGTH); nf=split(t,w,/[[:space:]]+/)
        for(i=1;i<=nf;i++) if (w[i] ~ /^[A-Z][A-Z0-9_]{2,}$/) bound[w[i]]=1
      }
      if (line ~ /^[[:space:]]*#[[:space:]]*Required env:/) {
        s2=line; sub(/^[[:space:]]*#[[:space:]]*Required env:/,"",s2)
        while (match(s2,/[A-Z][A-Z0-9_]{2,}/)) { bound[substr(s2,RSTART,RLENGTH)]=1; s2=substr(s2,RSTART+RLENGTH) }
      }
      next
    }
    # ---- pass 2: report unassigned refs inside bash fences ----
    {
      if (is_fence_open($0)) { inb=1; next }
      if (is_fence_close($0)) { inb=0; next }
      if (!inb) next
      line=$0
      gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*[:+?-][^}]*\}/,"@DEFAULTED@",line)
      s=line
      while (match(s,/\$\{?[A-Z][A-Z0-9_]{2,}/)) {
        tok=substr(s,RSTART,RLENGTH); sub(/^\$\{?/,"",tok); s=substr(s,RSTART+RLENGTH)
        if (tok ~ /^PIPELINE_/) continue
        if (tok in ok) continue
        if (tok in bound) continue
        if (!( (tok FNR) in seen)) { seen[tok FNR]=1; printf "%d\t%s\n", FNR, tok }
      }
    }
  ' "$1" "$1"
}

while IFS= read -r skill_md; do
  rel="${skill_md#$REPO_ROOT/}"
  hits="$(scan "$skill_md")"
  if [ -z "$hits" ]; then
    pass_msg "$rel: every var referenced in a bash fence is bound in one"
  else
    while IFS=$'\t' read -r ln name; do
      [ -n "$name" ] || continue
      fail_msg "$rel:$ln: \$$name referenced in a bash fence but never assigned/declared in one (#1215)"
    done <<< "$hits"
  fi
done <<< "$(find "$SKILL_ROOT" -maxdepth 2 -name SKILL.md | sort)"

# Targeted: MAIN_REPO assigned in the ## Boot BODY (not the YAML frontmatter).
LIT='MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"'
for rel in skills/fullsend/SKILL.md skills/campaign/SKILL.md; do
  boot="$(awk '/^## Boot/{f=1; next} f && /^## /{f=0} f' "$REPO_ROOT/$rel")"
  if [[ "$boot" == *"$LIT"* ]]; then
    pass_msg "$rel: ## Boot body assigns MAIN_REPO"
  else
    fail_msg "$rel: ## Boot body does not contain $LIT"
  fi
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
