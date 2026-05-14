"""Minimal pipeline.config parser for plugin-registered hooks.

Parses ``$CLAUDE_PROJECT_DIR/pipeline.config`` at hook fire time so the
manifest-registered hooks don't need install-time envsubst substitution.

Supports the four key shapes present in pipeline.config today:
  KEY="value", KEY='value', KEY=value, plus comments / blank lines.
Does NOT expand ``$(cmd)`` or ``${OTHER}`` interpolation — keys with
those values are returned literally.
"""
import os
import re
from pathlib import Path

_LINE_RE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$')


def _project_dir(project_dir=None) -> Path:
    if project_dir is not None:
        return Path(project_dir)
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))


def read(key: str, default: str = "", project_dir=None) -> str:
    cfg = _project_dir(project_dir) / "pipeline.config"
    try:
        text = cfg.read_text()
    except OSError:
        return default
    for line in text.splitlines():
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        m = _LINE_RE.match(line)
        if not m or m.group(1) != key:
            continue
        raw = m.group(2)
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
            return raw[1:-1]
        return raw
    return default
