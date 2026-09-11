"""Guards match a Bash command's ARGUMENT STRUCTURE, not its raw text.
Heredoc bodies and quoted-string interiors are masked before any regex sees
them, so a token that appears only in prose, a quoted operand or a
grep/awk/sed pattern is never a command. Segments headed by a shell word
(`bash -c`, `eval`, ...) keep their operands visible - they execute. An
unterminated quote leaves the text unmasked (fail closed).

Public API: mask_command(text), segments(text), head_index(words).
Shared by hooks/block_deletions.py and hooks/enforce-comment-trust.py
(issue #1321). Import-clean with `re` only (win32-safe).
"""
import re

MASK_CHAR = " "
SHELL_WORDS = {"bash", "sh", "zsh", "dash", "ksh", "eval", "source", "."}
INTERP_RE = re.compile(
    r"^(?:bash|sh|zsh|dash|ksh|eval|source|python[0-9.]*|node|perl|ruby)$"
)
WRAPPER_WORDS = {
    "sudo", "doas", "env", "nohup", "nice", "time", "timeout", "command",
    "exec", "builtin", "xargs", "stdbuf",
}
RESERVED = {"{", "!", "if", "then", "else", "elif", "do", "while", "until"}

_ASSIGN_RE = re.compile(r"^[A-Za-z_]\w*=")
_NUM_RE = re.compile(r"^\d+(?:\.\d+)?[smhd]?$")
_TRIGGER_RE = re.compile(r"^-[a-zA-Z]*c$")
_HEREDOC_OP_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\2")
_SEG_SPLIT_RE = re.compile(r"\|\||&&|[;&|(){]")
_PROBE_CHAR = "x"  # word-shaped filler so the heredoc delimiter group still matches


def _basename(word: str) -> str:
    return word.strip("\"'").rsplit("/", 1)[-1]


def head_index(words: list) -> int:
    """Index of the command word after skipping `NAME=` assignments, RESERVED
    words and WRAPPER_WORDS (by basename); once one of those has been
    skipped, also skip a `-flag` word or a bare positional value
    (`timeout 5`, `nice -n 5`). -1 when the segment has no command word."""
    skipped_any = False
    for i, w in enumerate(words):
        if _ASSIGN_RE.match(w):
            skipped_any = True
            continue
        base = _basename(w)
        if base in RESERVED or base in WRAPPER_WORDS:
            skipped_any = True
            continue
        if skipped_any and (w.startswith("-") or _NUM_RE.match(w)):
            continue
        return i
    return -1


def _probe_mask_quotes(line: str):
    """Length-preserving quote mask with a LETTER filler (_PROBE_CHAR), used
    only to locate heredoc operators without a quoted `<<` being mistaken for
    one. None on an unterminated quote."""
    out = []
    quote = ""
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if not quote:
            if ch == "\\":
                out.append(ch)
                out.append(line[i + 1]) if i + 1 < n else None
                i += 2 if i + 1 < n else 1
                continue
            if ch == "$" and line[i + 1:i + 2] == "'":
                out.append(ch)
                out.append(line[i + 1])
                quote = "$'"
                i += 2
                continue
            if ch in "\"'":
                quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "\\" and quote in ("$'", '"'):
            out.append(_PROBE_CHAR)
            if i + 1 < n:
                out.append("\n" if line[i + 1] == "\n" else _PROBE_CHAR)
                i += 2
            else:
                i += 1
            continue
        if ch == quote or (quote == "$'" and ch == "'"):
            quote = ""
            out.append(ch)
            i += 1
            continue
        out.append("\n" if ch == "\n" else _PROBE_CHAR)
        i += 1
    return None if quote else "".join(out)


def _segment_head_word(prefix: str) -> str:
    segs = _SEG_SPLIT_RE.split(prefix)
    words = (segs[-1] if segs else prefix).split()
    idx = head_index(words)
    return _basename(words[idx]) if idx != -1 else ""


def mask_heredoc_bodies(command: str) -> str:
    """Length-preserving: heredoc BODY lines -> MASK_CHAR fill; operator and
    terminator lines verbatim. A body owned by an INTERP_RE head word stays
    scanned (fail closed) - the rest of that command is left unmasked from
    that operator onward."""
    if "<<" not in command:
        return command
    out_lines = []
    queue: list = []
    for line in command.split("\n"):
        if queue:
            delimiter, dash = queue[0]
            content = line.lstrip("\t") if dash else line
            if content == delimiter:
                out_lines.append(line)
                queue.pop(0)
            else:
                out_lines.append(MASK_CHAR * len(line))
            continue
        out_lines.append(line)
        probe = _probe_mask_quotes(line)
        if probe is None:
            probe = line
        for m in _HEREDOC_OP_RE.finditer(probe):
            dash = m.group(1) == "-"
            delimiter = line[m.start(3):m.end(3)]
            if INTERP_RE.match(_segment_head_word(line[:m.start()])):
                queue = []
                break
            queue.append((delimiter, dash))
    return "\n".join(out_lines)


def _scan(text: str):
    """One pass: dequoted (start_offset, [words]) per segment (new segment on
    unquoted `;`, `&`, `|`, `(`, `)`, `\\n`) plus (segment_no, lo, hi, qchar)
    per quoted interior. None on an unterminated quote. Empty segments
    dropped (quoted spans in a dropped segment drop with it)."""
    segments_raw: list = []
    cur_words: list = []
    chars: list = []
    quote = ""
    interior_start = 0
    seg_start = 0
    quoted_raw: list = []
    i, n = 0, len(text)

    def flush_word():
        if chars:
            cur_words.append("".join(chars))
            chars.clear()

    def flush_segment(next_start):
        nonlocal seg_start
        flush_word()
        segments_raw.append((seg_start, cur_words[:]))
        cur_words.clear()
        seg_start = next_start

    while i < n:
        ch = text[i]
        if not quote:
            if ch == "\\":
                chars.append(ch)
                if i + 1 < n:
                    chars.append(text[i + 1])
                    i += 2
                else:
                    i += 1
                continue
            if ch == "$" and text[i + 1:i + 2] == "'":
                quote = "$'"
                interior_start = i + 2
                i += 2
                continue
            if ch in "\"'":
                quote = ch
                interior_start = i + 1
                i += 1
                continue
            if ch in " \t":
                flush_word()
                i += 1
                continue
            if ch == "\n" or ch in ";&|()":
                flush_segment(i + 1)
                i += 1
                continue
            chars.append(ch)
            i += 1
            continue
        # inside a quoted region
        if ch == "\\" and quote in ("$'", '"'):
            chars.append(ch)
            if i + 1 < n:
                chars.append(text[i + 1])
                i += 2
            else:
                i += 1
            continue
        if ch == quote or (quote == "$'" and ch == "'"):
            quoted_raw.append((len(segments_raw), interior_start, i, quote))
            quote = ""
            i += 1
            continue
        chars.append(ch)
        i += 1

    if quote:
        return None
    flush_segment(n)

    remap = {}
    filtered = []
    for idx, seg in enumerate(segments_raw):
        if seg[1]:
            remap[idx] = len(filtered)
            filtered.append(seg)
    quoted = [
        (remap[s], lo, hi, qc) for (s, lo, hi, qc) in quoted_raw if s in remap
    ]
    return filtered, quoted


def segments(command: str):
    """List of (start_offset, [dequoted words]) per shell segment; a segment
    headed by a SHELL_WORDS word recurses ONE level into its `-c`/`-lc`/...
    operand (or, for `eval`, the rest of its words) and appends those
    segments at the parent's offset. None on an unterminated quote."""
    scanned = _scan(mask_heredoc_bodies(command))
    if scanned is None:
        return None
    segs, _ = scanned
    result = list(segs)
    for start, words in segs:
        idx = head_index(words)
        if idx == -1:
            continue
        base = _basename(words[idx])
        if base not in SHELL_WORDS:
            continue
        if base == "eval":
            inner_text = " ".join(words[idx + 1:])
        else:
            trigger = next(
                (j for j in range(idx + 1, len(words)) if _TRIGGER_RE.match(words[j])),
                None,
            )
            inner_text = words[trigger + 1] if trigger is not None and trigger + 1 < len(words) else ""
        if not inner_text:
            continue
        inner = _scan(inner_text)
        if inner is None:
            return None
        inner_segs, _ = inner
        result.extend((start, iwords) for _, iwords in inner_segs if iwords)
    return result


def mask_command(command: str) -> str:
    """Heredoc-masked text with every quoted interior blanked, EXCEPT an
    operand of a SHELL_WORDS-headed segment (it executes) and EXCEPT a
    DOUBLE-quoted interior containing `$(` or a backtick (bash expands it).
    Length-preserving; returns the heredoc-masked text unchanged when the
    scan hits an unterminated quote."""
    text = mask_heredoc_bodies(command)
    scanned = _scan(text)
    if scanned is None:
        return text
    segs, quoted = scanned
    out = list(text)
    for seg_idx, lo, hi, qchar in quoted:
        _, words = segs[seg_idx]
        idx = head_index(words)
        base = _basename(words[idx]) if idx != -1 else ""
        if base in SHELL_WORDS:
            continue
        if qchar == '"':
            interior = text[lo:hi]
            if "$(" in interior or "`" in interior:
                continue
        for k in range(lo, hi):
            if out[k] != "\n":
                out[k] = MASK_CHAR
    return "".join(out)
