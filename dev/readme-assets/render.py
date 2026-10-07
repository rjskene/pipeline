#!/usr/bin/env python3
"""Render the README rail diagrams to docs/assets/*.svg (light + dark).

The README embeds each rail through a <picture> element so GitHub picks the
variant matching the viewer's colour scheme. GitHub serves repo SVGs through a
sanitising proxy that strips CSS custom properties, so every colour is baked in
per variant here instead of resolved at view time.

Usage:
  python3 dev/readme-assets/render.py            # write docs/assets/*.svg
  python3 dev/readme-assets/render.py --check    # exit 1 when any file would change

Guard: tests/test-readme-assets.sh runs --check so the committed SVGs can never
drift from this template.
"""
from __future__ import annotations

import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "docs", "assets")

SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace"

PALETTES = {
    "light": dict(
        ground="#F6F7F5", surface="#FFFFFF", frame="#DDE2E0", ink="#1C2326",
        ink2="#4E5B60", muted="#7A878C", accent="#0B6E7F", accent_soft="#E3F1F3",
        code_bg="#EEF2F1", ok="#2B8A4B", hold="#B86E00",
    ),
    "dark": dict(
        ground="#0F1516", surface="#161E20", frame="#2A3537", ink="#E4ECEA",
        ink2="#AEBCB9", muted="#7E8F8C", accent="#5FC2D1", accent_soft="#15363B",
        code_bg="#1E2A2C", ok="#5BC77A", hold="#E6A23C",
    ),
}


def marker(mid: str, fill: str) -> str:
    return (
        f'<marker id="{mid}" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" '
        f'markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L8,4 L0,8 z" '
        f'fill="{fill}"/></marker>'
    )


def pill(x: int, y: int, w: int, h: int, label: str, p: dict, *, decides: bool = False,
         dashed: bool = False, fs: float = 12.5, rx: int = 6) -> str:
    if decides:
        box = f'fill="{p["accent_soft"]}" stroke="{p["accent"]}" stroke-width="1.4"'
    elif dashed:
        box = f'fill="none" stroke="{p["frame"]}" stroke-dasharray="4 3"'
    else:
        box = f'fill="{p["surface"]}" stroke="{p["frame"]}" stroke-width="1.2"'
    ink = p["ink2"] if dashed else p["ink"]
    cx, cy = x + w / 2, y + h / 2 + fs * 0.35
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" {box}/>'
        f'<text x="{cx:g}" y="{cy:g}" fill="{ink}" font-size="{fs}" text-anchor="middle">{label}</text>'
    )


def svg_open(w: int, h: int, label: str, p: dict, defs: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
        f'role="img" aria-label="{label}" font-family="{SANS}">\n'
        f'<defs>{defs}</defs>\n'
        f'<rect x="0" y="0" width="{w}" height="{h}" fill="{p["ground"]}"/>\n'
    )


def lifecycle(p: dict) -> str:
    stages = [
        ("classify", "agent", False),
        ("plan", "agent", False),
        ("plan-eval", "agent · decides", True),
        ("execute", "agent · own worktree", False),
        ("pr-eval preflight", "script", False),
        ("pr-eval", "agent · decides", True),
        ("auto-merge gate", "script · decides", True),
    ]
    out = [svg_open(920, 215, "Pipeline lifecycle rail", p,
                    marker("ah", p["ink2"]) + marker("aha", p["accent"]))]
    # PATH D bypass: plan is posted, plan-eval is skipped (auto-approved).
    out.append(f'<path d="M204,62 V34 H460 V62" fill="none" stroke="{p["muted"]}" stroke-width="1.2" '
               f'stroke-dasharray="4 3" marker-end="url(#ah)"/>')
    out.append(f'<text x="332" y="28" text-anchor="middle" font-size="11" fill="{p["muted"]}">'
               f'PATH D skips plan-eval (auto-approved)</text>')
    out.append(f'<g stroke="{p["ink2"]}" stroke-width="1.4" fill="none" marker-end="url(#ah)">')
    for i in range(6):
        x = 135 + i * 128
        out.append(f'<path d="M{x},82 H{x + 8}"/>')
    out.append("</g>")
    for i, (label, who, decides) in enumerate(stages):
        x = 17 + i * 128
        out.append(pill(x, 62, 118, 40, label, p, decides=decides))
        out.append(f'<text x="{x + 59}" y="118" text-anchor="middle" font-family="{MONO}" '
                   f'font-size="10.5" fill="{p["muted"]}">{who}</text>')
    out.append(f'<text x="332" y="140" text-anchor="middle" font-size="11" fill="{p["ink2"]}">'
               f'Approve · Revise → amendments bind execute</text>')
    out.append(f'<path d="M716,126 V150 H588 V126" fill="none" stroke="{p["accent"]}" stroke-width="1.3" '
               f'marker-end="url(#aha)"/>')
    out.append(f'<text x="652" y="164" text-anchor="middle" font-size="11" fill="{p["accent"]}">'
               f'Revise → fix → re-check</text>')
    out.append(f'<path d="M844,126 V142" fill="none" stroke="{p["ink2"]}" stroke-width="1.2"/>')
    out.append(f'<text x="903" y="158" text-anchor="end" font-size="11" fill="{p["ok"]}">green → merged</text>')
    out.append(f'<text x="903" y="176" text-anchor="end" font-size="11" fill="{p["hold"]}">block-* → held for operator</text>')
    out.append("</svg>\n")
    return "\n".join(out)


def paths(p: dict) -> str:
    lanes = [
        ("A · docs-only", "plan", "flat edit → commit, no test cycle"),
        ("B · standard", "plan", "red → green → commit, per task"),
        ("C · multi-task", "plan", "fan-out per target dir → cherry-pick"),
        ("D · quick-fix", "auto-approved", "inline red → green → commit"),
    ]
    ys = [42, 102, 162, 222]
    out = [svg_open(920, 262, "Path routing fan", p, marker("ah", p["ink2"]))]
    out.append(pill(17, 112, 100, 40, "classify", p, decides=True))
    out.append(f'<text x="67" y="168" text-anchor="middle" font-family="{MONO}" font-size="10.5" '
               f'fill="{p["muted"]}">agent · decides</text>')
    out.append(f'<path d="M117,132 H134 M134,42 V222" fill="none" stroke="{p["ink2"]}" stroke-width="1.4"/>')
    out.append(f'<g stroke="{p["ink2"]}" stroke-width="1.4" fill="none" marker-end="url(#ah)">')
    for y in ys:
        out.append(f'<path d="M134,{y} H150"/>')
    out.append("</g>")
    out.append(f'<g stroke="{p["ink2"]}" stroke-width="1.2" fill="none" marker-end="url(#ah)">')
    for y in ys:
        out.append(f'<path d="M264,{y} H280"/><path d="M400,{y} H416"/>')
    out.append("</g>")
    for (lane, plan, execute), y in zip(lanes, ys):
        out.append(f'<rect x="152" y="{y - 14}" width="112" height="28" rx="4" fill="{p["code_bg"]}"/>')
        out.append(f'<text x="162" y="{y + 4}" font-family="{MONO}" font-size="11.5" fill="{p["ink"]}">{lane}</text>')
        dashed = plan != "plan"
        out.append(pill(282, y - 14, 118, 28, plan, p, dashed=dashed, fs=11.5 if dashed else 12.5, rx=5))
        out.append(pill(418, y - 14, 232, 28, execute, p, rx=5))
        out.append(f'<text x="668" y="{y + 4}" font-family="{MONO}" font-size="10.5" fill="{p["muted"]}">opus</text>')
    out.append(f'<text x="668" y="18" font-family="{MONO}" font-size="10.5" fill="{p["muted"]}">execute model</text>')
    out.append(f'<g stroke="{p["ink2"]}" stroke-width="1.4" fill="none">')
    for y in ys:
        out.append(f'<path d="M650,{y} H658"/>')
    out.append(f'<path d="M704,42 V222"/>')
    for y in ys:
        out.append(f'<path d="M696,{y} H704"/>')
    out.append("</g>")
    out.append(f'<path d="M704,132 H720" fill="none" stroke="{p["ink2"]}" stroke-width="1.4" marker-end="url(#ah)"/>')
    out.append(pill(722, 112, 80, 40, "PR", p))
    out.append(f'<path d="M802,132 H818" fill="none" stroke="{p["ink2"]}" stroke-width="1.4" marker-end="url(#ah)"/>')
    out.append(pill(820, 112, 84, 40, "pr-eval", p, decides=True))
    out.append(f'<text x="762" y="168" text-anchor="middle" font-family="{MONO}" font-size="10.5" '
               f'fill="{p["muted"]}">→ staging</text>')
    out.append(f'<text x="862" y="168" text-anchor="middle" font-family="{MONO}" font-size="10.5" '
               f'fill="{p["muted"]}">+ merge gate</text>')
    out.append("</svg>\n")
    return "\n".join(out)


def branches(p: dict) -> str:
    out = [svg_open(920, 200, "Branch and release flow", p,
                    marker("ah", p["ink2"]) + marker("aha", p["accent"]))]
    out.append(pill(197, 14, 100, 30, "next", p, dashed=True))
    out.append(f'<text x="120" y="33" text-anchor="middle" font-size="11" fill="{p["muted"]}">'
               f'issues labelled next →</text>')
    out.append(f'<path d="M247,44 V62" fill="none" stroke="{p["muted"]}" stroke-width="1.2" '
               f'stroke-dasharray="4 3" marker-end="url(#ah)"/>')
    out.append(f'<text x="330" y="56" font-family="{MONO}" font-size="10.5" fill="{p["muted"]}">merge-back PR</text>')
    out.append(pill(17, 64, 130, 40, "feature/&lt;slug&gt;", p))
    out.append(pill(197, 64, 100, 40, "staging", p, decides=True))
    out.append(pill(347, 64, 90, 40, "main", p))
    out.append(pill(487, 64, 110, 40, "release PR", p))
    out.append(pill(647, 64, 110, 40, "vX.Y.Z tag", p))
    out.append(pill(807, 64, 96, 40, "release/vX.Y", p, dashed=True))
    out.append(f'<g stroke="{p["ink2"]}" stroke-width="1.4" fill="none" marker-end="url(#ah)">'
               f'<path d="M147,84 H195"/><path d="M297,84 H345"/><path d="M437,84 H485"/><path d="M597,84 H645"/></g>')
    out.append(f'<path d="M757,84 H805" fill="none" stroke="{p["muted"]}" stroke-width="1.2" '
               f'stroke-dasharray="4 3" marker-end="url(#ah)"/>')
    pill_notes = [(82, "one per issue"), (392, "release branch")]
    edge_notes = [
        (171, "PR · merge-commit", ""),
        (322, "promotion PR", "operator"),
        (462, "release-please", "feat → minor · fix → patch"),
        (622, "merge → tag", "+ GitHub Release"),
        (781, "wind-back line", "optional"),
    ]
    out.append(f'<g font-family="{MONO}" font-size="10.5" fill="{p["muted"]}" text-anchor="middle">')
    for x, a in pill_notes:
        out.append(f'<text x="{x}" y="120">{a}</text>')
    for x, a, b in edge_notes:
        out.append(f'<text x="{x}" y="140">{a}</text>')
        if b:
            out.append(f'<text x="{x}" y="154">{b}</text>')
    out.append("</g>")
    out.append(f'<path d="M702,104 V172 H247 V106" fill="none" stroke="{p["accent"]}" stroke-width="1.3" '
               f'marker-end="url(#aha)"/>')
    out.append(f'<text x="474" y="188" text-anchor="middle" font-size="11" fill="{p["accent"]}">'
               f'back-sync-release workflow merges the release commit back into staging</text>')
    out.append("</svg>\n")
    return "\n".join(out)


def trust(p: dict) -> str:
    left = [
        ("PRs target staging, never main", "Bash"),
        ("no CI-skip markers in commits or PRs", "Bash"),
        ("PATH C: orchestrator never edits impl files", "Edit · Write"),
        ("no yield while CI is still running", "Stop"),
        ("headless: unanswered escalations are denied", "PermissionRequest"),
    ]
    right = [
        "Claude Code permission mode and the bridge policy",
        "which repos, branches and tokens the session can reach",
        "deleting worktrees, pruning logs, force-pushing anything",
        "branch protection on main",
        "promoting staging → main and cutting the release",
    ]
    out = [svg_open(920, 236, "Trust boundary", p, "")]
    out.append(f'<rect x="17" y="14" width="432" height="208" rx="8" fill="{p["surface"]}" stroke="{p["frame"]}" stroke-width="1.2"/>')
    out.append(f'<rect x="471" y="14" width="432" height="208" rx="8" fill="none" stroke="{p["accent"]}" '
               f'stroke-width="1.4" stroke-dasharray="5 4"/>')
    out.append(f'<g font-size="13" font-weight="600" fill="{p["ink"]}">'
               f'<text x="33" y="40">Ships with the plugin · hooks/</text>'
               f'<text x="487" y="40">Operator owns · outside the repo</text></g>')
    out.append(f'<g font-family="{MONO}" font-size="10.5" fill="{p["muted"]}">'
               f'<text x="33" y="56">PreToolUse tripwires by tool matcher, plus two lifecycle hooks</text>'
               f'<text x="487" y="56">the actual boundary</text></g>')
    for i, ((text, hook), rtext) in enumerate(zip(left, right)):
        y = 86 + i * 26
        out.append(f'<text x="33" y="{y}" font-size="12" fill="{p["ink"]}">{text}</text>')
        out.append(f'<text x="433" y="{y}" text-anchor="end" font-family="{MONO}" font-size="10" '
                   f'fill="{p["accent"]}">{hook}</text>')
        out.append(f'<text x="487" y="{y}" font-size="12" fill="{p["ink"]}">{rtext}</text>')
        if i < 4:
            out.append(f'<g stroke="{p["frame"]}" stroke-width="1"><path d="M33,{y + 10} H433"/>'
                       f'<path d="M487,{y + 10} H887"/></g>')
    out.append("</svg>\n")
    return "\n".join(out)


RAILS = {"lifecycle": lifecycle, "paths": paths, "branches": branches, "trust": trust}


def render_all() -> dict[str, str]:
    files = {}
    for name, fn in RAILS.items():
        for variant, p in PALETTES.items():
            suffix = "" if variant == "light" else "-dark"
            files[f"{name}{suffix}.svg"] = fn(p)
    return files


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if any output would change")
    ap.add_argument("--out", default=OUT_DIR)
    args = ap.parse_args()
    files = render_all()
    drift = []
    for fname, content in files.items():
        path = os.path.join(args.out, fname)
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if current == content:
            continue
        if args.check:
            drift.append(fname)
        else:
            os.makedirs(args.out, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
            print(f"wrote {os.path.relpath(path, ROOT)}")
    if drift:
        print("DRIFT: " + " ".join(sorted(drift)), file=sys.stderr)
        print("re-run: python3 dev/readme-assets/render.py", file=sys.stderr)
        return 1
    if args.check:
        print(f"OK: {len(files)} rail SVGs match the template")
    return 0


if __name__ == "__main__":
    sys.exit(main())
