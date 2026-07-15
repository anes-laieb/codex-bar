#!/usr/bin/env python3
"""codex-config.py — safe, surgical editor for ~/.codex/config.toml.

The only key this tool ever changes is the root-level `notify`. It does a
line-based edit (never a parse-and-reserialize) so every comment, table, and
byte of unrelated config is preserved exactly. No third-party TOML library is
required, which keeps install dependency-free on stock macOS Python.

Subcommands:
  show-notify                    Print the current root-level notify line.
  get-notify                     Print the current notify as a JSON array (or "null").
  set-notify [opts] ARG [ARG...] Set `notify = [ARG, ...]` (backs up first).
  chain-notify [opts] PROG [ARG...]
                                 Prepend PROG (+ARGs) to the existing notify so a
                                 prior hook still runs: notify = [PROG, ARGs..., <old>...].
  restore BACKUP                 Overwrite config.toml with BACKUP.

Options (set-notify / chain-notify):
  --dry-run      Print the unified diff + the backup that WOULD be made; write nothing.
  --force        Replace/extend even a multi-line notify (otherwise refused).
  --config PATH  Operate on PATH instead of $CODEX_HOME/config.toml.

On a successful write, the last stdout line is `BACKUP=<path>` (machine-readable
for install/uninstall). Exit codes: 0 ok · 2 usage/IO error · 3 refused.
"""
import argparse
import difflib
import json
import os
import sys
import time


def config_path(explicit):
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    return os.path.join(home, "config.toml")


def read_lines(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read().splitlines(keepends=True)


def find_root_notify(lines):
    """Return (index, is_multiline) of the root-level `notify` key, or (-1, False).

    Root-level means before the first `[table]` header; a `notify` inside a
    table is a different key and is left alone.
    """
    in_table = False
    for i, raw in enumerate(lines):
        s = raw.strip()
        if s.startswith("[") and not s.startswith("[["):
            in_table = True
        if in_table:
            continue
        stripped = raw.lstrip()
        if stripped.startswith("notify"):
            rest = stripped[len("notify"):].lstrip()
            if rest.startswith("="):
                val = rest[1:].strip()
                multiline = val.startswith("[") and ("]" not in val)
                return i, multiline
    return -1, False


def current_notify_array(lines):
    """Parse the existing single-line notify into a Python list, or None.

    TOML arrays of double-quoted strings are valid JSON, so json.loads suffices
    for the single-line case. Returns (array_or_None, idx, is_multiline).
    """
    idx, multi = find_root_notify(lines)
    if idx < 0 or multi:
        return None, idx, multi
    raw = lines[idx].split("=", 1)[1].strip()
    try:
        arr = json.loads(raw)
        if isinstance(arr, list):
            return arr, idx, multi
    except Exception:
        pass
    return None, idx, multi


def toml_array(args):
    return "notify = [" + ", ".join(json.dumps(a) for a in args) + "]\n"


def first_table_index(lines):
    for i, raw in enumerate(lines):
        if raw.lstrip().startswith("["):
            return i
    return len(lines)


def _apply_notify(path, args, dry_run, force):
    """Set the root notify key to `args` (a list of strings). Surgical + safe."""
    if not os.path.exists(path):
        print(f"error: no config at {path}", file=sys.stderr)
        return 2
    lines = read_lines(path)
    idx, multi = find_root_notify(lines)
    if idx >= 0 and multi and not force:
        print("refused: existing `notify` spans multiple lines. Edit by hand or use --force.",
              file=sys.stderr)
        return 3

    new_line = toml_array(args)
    new_lines = list(lines)
    if idx >= 0:
        new_lines[idx] = new_line
    else:
        ins = first_table_index(new_lines)
        block = [new_line]
        if ins < len(new_lines) and new_lines[ins].strip() != "":
            block.append("\n")
        new_lines[ins:ins] = block

    diff = "".join(difflib.unified_diff(lines, new_lines,
                                        fromfile="config.toml", tofile="config.toml (new)"))
    if not diff:
        print("no change needed; notify already set to that value.")
        return 0

    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = f"{path}.bak.{ts}"
    print(diff, end="")
    if dry_run:
        print(f"\n# dry-run: nothing written. would back up -> {backup}")
        return 0

    with open(backup, "w", encoding="utf-8") as f:
        f.writelines(lines)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)

    # Sanity: everything except our single notify line must be unchanged.
    check = read_lines(path)
    cidx, _ = find_root_notify(check)
    orig_wo = [l for i, l in enumerate(lines) if not (idx >= 0 and i == idx)]
    new_wo = [l for i, l in enumerate(check) if not (cidx >= 0 and i == cidx)]
    if idx < 0:
        new_wo = [l for l in new_wo if l != new_line]
    if idx >= 0 and orig_wo != new_wo:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines)
        print("error: edit changed unrelated lines; restored from original.", file=sys.stderr)
        return 2

    print(f"# wrote {path}")
    print(f"BACKUP={backup}")
    return 0


def do_show(path):
    if not os.path.exists(path):
        print(f"(no config at {path})")
        return 0
    lines = read_lines(path)
    idx, multi = find_root_notify(lines)
    if idx < 0:
        print("(no root-level notify key)")
    else:
        print(lines[idx].rstrip("\n"))
        if multi:
            print("(note: notify value spans multiple lines)")
    return 0


def do_get(path):
    if not os.path.exists(path):
        print("null")
        return 0
    arr, _idx, _multi = current_notify_array(read_lines(path))
    print(json.dumps(arr) if arr is not None else "null")
    return 0


def do_chain(path, prog, extra, dry_run, force):
    if not os.path.exists(path):
        print(f"error: no config at {path}", file=sys.stderr)
        return 2
    arr, idx, multi = current_notify_array(read_lines(path))
    if idx >= 0 and multi and not force:
        print("refused: existing `notify` spans multiple lines. Edit by hand or use --force.",
              file=sys.stderr)
        return 3
    existing = arr if arr else []
    # Don't double-chain if we're already the front of the array.
    if existing[:1] == [prog]:
        print("no change needed; already chained at the front.")
        return 0
    new = [prog] + list(extra) + existing
    return _apply_notify(path, new, dry_run, force)


def do_restore(path, backup):
    backup = os.path.abspath(os.path.expanduser(backup))
    if not os.path.exists(backup):
        print(f"error: backup not found: {backup}", file=sys.stderr)
        return 2
    with open(backup, "r", encoding="utf-8") as f:
        data = f.read()
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)
    print(f"restored {path} <- {backup}")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="codex-config.py", add_help=True)
    ap.add_argument("--config", default=None, help="path to config.toml")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show-notify")
    sub.add_parser("get-notify")
    sp = sub.add_parser("set-notify")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--force", action="store_true")
    sp.add_argument("args", nargs="+")
    cp = sub.add_parser("chain-notify")
    cp.add_argument("--dry-run", action="store_true")
    cp.add_argument("--force", action="store_true")
    cp.add_argument("prog")
    cp.add_argument("extra", nargs="*")
    rp = sub.add_parser("restore")
    rp.add_argument("backup")
    ns = ap.parse_args(argv)
    path = config_path(ns.config)
    if ns.cmd == "show-notify":
        return do_show(path)
    if ns.cmd == "get-notify":
        return do_get(path)
    if ns.cmd == "set-notify":
        return _apply_notify(path, ns.args, ns.dry_run, ns.force)
    if ns.cmd == "chain-notify":
        return do_chain(path, ns.prog, ns.extra, ns.dry_run, ns.force)
    if ns.cmd == "restore":
        return do_restore(path, ns.backup)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
