#!/usr/bin/env python3
"""Validate Tidewrack dialogue graphs without needing the Godot engine.

Checks, for every data/dialogue/*.json file:
  - it parses as a JSON object of node_id -> node
  - each node is either a linear node ("next": id|null) or a choice node
    ("choices": [{text, next, set_flag?}]) — not neither, not both
  - every referenced target id exists
  - at least one terminal (next == null) is reachable from an entry point
  - reports orphan nodes (unreachable from any known entry) as warnings

Then prints a flag report: every story flag, where the dialogue sets it (and
to what), where the GDScript reads it, and any flag that is set but never
read or read but never set. Journal entries recorded via "discover" are
listed the same way.

Exit code 0 = all valid, 1 = at least one error. The flag report only ever
adds warnings; it never fails the run.

Usage:  python3 tests/validate_dialogue.py [--no-flags]
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

# Entry-point node ids the game starts graphs from (see scripts/game.gd).
KNOWN_ENTRIES = {"logbook", "radio", "door", "start"}

ROOT = Path(__file__).resolve().parent.parent
DIALOGUE_DIR = ROOT / "data" / "dialogue"
SCRIPTS_DIR = ROOT / "scripts"

# Journal entries are recorded by dialogue nodes with "discover": "<entry id>";
# ids are expected to carry this prefix (see scripts/autoload/journal.gd).
JOURNAL_ENTRY_PREFIX = "entry_"


def reachable(graph: dict, entries: set[str]) -> set[str]:
    seen: set[str] = set()
    stack = [e for e in entries if e in graph]
    while stack:
        nid = stack.pop()
        if nid in seen:
            continue
        seen.add(nid)
        node = graph[nid]
        targets: list[str] = []
        if isinstance(node.get("choices"), list):
            targets += [c.get("next") for c in node["choices"]]
        if "next" in node:
            targets.append(node.get("next"))
        for t in targets:
            if isinstance(t, str) and t in graph:
                stack.append(t)
    return seen


def validate_file(path: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    try:
        graph = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        return [f"{path.name}: invalid JSON — {exc}"], warnings

    if not isinstance(graph, dict):
        return [f"{path.name}: top level must be an object of node_id -> node"], warnings

    has_terminal = False
    for nid, node in graph.items():
        if not isinstance(node, dict):
            errors.append(f"{path.name}:{nid}: node must be an object")
            continue

        has_choices = isinstance(node.get("choices"), list) and len(node["choices"]) > 0
        has_next = "next" in node

        if not has_choices and not has_next:
            errors.append(f"{path.name}:{nid}: node has neither 'next' nor 'choices'")
        if has_choices and has_next:
            errors.append(f"{path.name}:{nid}: node has both 'next' and 'choices' (ambiguous)")

        if has_next and node.get("next") is None:
            has_terminal = True

        if has_next and isinstance(node.get("next"), str) and node["next"] not in graph:
            errors.append(f"{path.name}:{nid}: 'next' points to missing node '{node['next']}'")

        if has_choices:
            for i, choice in enumerate(node["choices"]):
                if not isinstance(choice, dict) or "text" not in choice:
                    errors.append(f"{path.name}:{nid}: choice #{i} needs a 'text' field")
                    continue
                target = choice.get("next")
                if target is not None and (not isinstance(target, str) or target not in graph):
                    errors.append(f"{path.name}:{nid}: choice #{i} 'next' -> missing node '{target}'")
                if target is None:
                    has_terminal = True

    if not has_terminal:
        errors.append(f"{path.name}: no terminal node (a node with next == null) — the graph never ends")

    entries = KNOWN_ENTRIES & set(graph.keys())
    if not entries:
        warnings.append(f"{path.name}: no known entry point ({sorted(KNOWN_ENTRIES)}) present")
    else:
        seen = reachable(graph, entries)
        for orphan in sorted(set(graph) - seen):
            warnings.append(f"{path.name}:{orphan}: unreachable from entry points {sorted(entries)}")

    return errors, warnings


# --- Flag report ------------------------------------------------------------

def collect_flag_sites(files: list[Path]) -> tuple[dict, dict]:
    """Where dialogue sets each flag, and where it records journal entries.

    Returns (flags, discovers):
      flags:     flag -> list of (location, value) e.g. ("keeper_intro.json:logbook_choice1/choice#0", True)
      discovers: entry id -> list of locations
    """
    flags: dict[str, list[tuple[str, object]]] = defaultdict(list)
    discovers: dict[str, list[str]] = defaultdict(list)
    for path in files:
        try:
            graph = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        if not isinstance(graph, dict):
            continue
        for nid, node in graph.items():
            if not isinstance(node, dict):
                continue
            where = f"{path.name}:{nid}"
            for flag, value in (node.get("set_flag") or {}).items():
                flags[str(flag)].append((where, value))
            if "discover" in node:
                discovers[str(node["discover"])].append(where)
            for i, choice in enumerate(node.get("choices") or []):
                if isinstance(choice, dict):
                    for flag, value in (choice.get("set_flag") or {}).items():
                        flags[str(flag)].append((f"{where}/choice#{i}", value))
    return flags, discovers


_GET_FLAG = re.compile(r'get_flag\(\s*"([^"]+)"')
_SET_FLAG = re.compile(r'set_flag\(\s*"([^"]+)"')


def collect_script_sites() -> tuple[dict, dict]:
    """Where GDScript reads (get_flag) and writes (set_flag) each flag by name."""
    reads: dict[str, list[str]] = defaultdict(list)
    writes: dict[str, list[str]] = defaultdict(list)
    for path in sorted(SCRIPTS_DIR.rglob("*.gd")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            where = f"{path.relative_to(ROOT)}:{lineno}"
            for m in _GET_FLAG.finditer(line):
                reads[m.group(1)].append(where)
            for m in _SET_FLAG.finditer(line):
                writes[m.group(1)].append(where)
    return reads, writes


def flag_report(files: list[Path]) -> list[str]:
    """Print the flag report; return warnings it raised."""
    warnings: list[str] = []
    set_in_dialogue, discovers = collect_flag_sites(files)
    read_in_code, set_in_code = collect_script_sites()

    all_flags = sorted(set(set_in_dialogue) | set(read_in_code) | set(set_in_code))
    print("Flag report")
    print(f"  {len(all_flags)} flag(s): {len(set_in_dialogue)} set by dialogue, "
          f"{len(set_in_code)} set by code, {len(read_in_code)} read by code")
    for flag in all_flags:
        print(f"  {flag}")
        for where, value in set_in_dialogue.get(flag, []):
            print(f"    set   {where}  = {json.dumps(value)}")
        for where in set_in_code.get(flag, []):
            print(f"    set   {where}  (code)")
        for where in read_in_code.get(flag, []):
            print(f"    read  {where}")
        is_set = flag in set_in_dialogue or flag in set_in_code
        if not read_in_code.get(flag):
            print("    read  —")
            warnings.append(f"flag '{flag}' is set but never read: no get_flag() in scripts/")
        if not is_set:
            print("    set   —")
            warnings.append(f"flag '{flag}' is read but never set: no set_flag in dialogue or scripts/")
        values = {json.dumps(v) for _, v in set_in_dialogue.get(flag, [])}
        if len(values) > 1:
            print(f"    note  set to more than one value: {', '.join(sorted(values))}")

    print(f"  {len(discovers)} journal entr{'y' if len(discovers) == 1 else 'ies'} recorded via \"discover\"")
    for entry in sorted(discovers):
        print(f"  {entry}")
        for where in discovers[entry]:
            print(f"    discover  {where}")
        if not entry.startswith(JOURNAL_ENTRY_PREFIX):
            warnings.append(f"journal entry '{entry}' does not use the '{JOURNAL_ENTRY_PREFIX}' prefix")
    return warnings


def main(argv: list[str]) -> int:
    show_flags = "--no-flags" not in argv
    files = sorted(DIALOGUE_DIR.glob("*.json"))
    if not files:
        print(f"No dialogue files found in {DIALOGUE_DIR}")
        return 1

    all_errors: list[str] = []
    all_warnings: list[str] = []
    for path in files:
        errs, warns = validate_file(path)
        all_errors += errs
        all_warnings += warns
        status = "OK" if not errs else "FAIL"
        print(f"[{status}] {path.relative_to(ROOT)}  ({len(json.loads(path.read_text()))} nodes)")

    for w in all_warnings:
        print(f"  warning: {w}")
    for e in all_errors:
        print(f"  ERROR:   {e}")

    if show_flags:
        print()
        flag_warnings = flag_report(files)
        for w in flag_warnings:
            print(f"  warning: {w}")
        all_warnings += flag_warnings

    print()
    if all_errors:
        print(f"✗ {len(all_errors)} error(s), {len(all_warnings)} warning(s)")
        return 1
    print(f"✓ all dialogue graphs valid ({len(all_warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

