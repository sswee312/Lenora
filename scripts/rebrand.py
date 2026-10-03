#!/usr/bin/env python3
"""Rename every Palmier derivative to Lenora in file contents and paths. Repeatable."""
import re
import sys
from pathlib import Path

# (regex, replacement), tried in order at each position; longest and most specific first.
MAPPING = [
    (re.escape("io.palmier.project"), "xyz.agentage.lenora.project"),
    (re.escape("io.palmier.pro"), "xyz.agentage.lenora"),
    (re.escape("palmier://"), "lenora://"),
    (re.escape("palmier.io/docs"), "github.com/vermatushar/Lenora#readme"),
    (re.escape("palmier.io"), "github.com/vermatushar/Lenora"),
    (re.escape("palmier-io/palmier-skills"), "vermatushar/Lenora/tree/main/skills"),
    (re.escape("palmier-io/"), "vermatushar/"),
    (r"PalmierPro(?![a-z])", "Lenora"),
    (re.escape("palmier-pro"), "lenora"),
    (re.escape("palmier.pro"), "lenora"),
    (re.escape(".palmier"), ".lenora"),
    ("PALMIER", "LENORA"),
    ("Palmier", "Lenora"),
    ("palmier", "lenora"),
]
PATTERN = re.compile("|".join(f"({regex})" for regex, _ in MAPPING))
ALLOW_MARKER = "rebrand:allow"
SKIP_DIRS = {".git", ".superpowers", ".pytest_cache", ".build", ".swiftpm", ".venv", "node_modules", "__pycache__"}
ALLOW_FILES = {"NOTICE", "LICENSE", "scripts/rebrand.py", "scripts/test_rebrand.py"}
ALLOW_PREFIXES = ("docs/",)
VENDOR_IMPORT = re.compile(r"^\s*(@preconcurrency\s+)?import\s+(ConvexMobile|Clerk\w*|Sparkle|Sentry\w*|PostHog)\b")
VENDOR_PACKAGE = re.compile(r"convex|clerk|sparkle-project|sentry-cocoa|posthog", re.IGNORECASE)


def rewrite(text: str) -> str:
    return PATTERN.sub(lambda m: MAPPING[m.lastindex - 1][1], text)


def rewrite_lines(text: str) -> str:
    return "".join(
        line if ALLOW_MARKER in line else rewrite(line) for line in text.splitlines(keepends=True)
    )


def _allowed(rel: str) -> bool:
    return rel in ALLOW_FILES or rel.startswith(ALLOW_PREFIXES)


def _files(root: Path):
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts) or not path.is_file():
            continue
        yield path, rel.as_posix()


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


def run(root: Path) -> None:
    for path, rel in list(_files(root)):
        if _allowed(rel):
            continue
        text = _read_text(path)
        if text is not None:
            new = rewrite_lines(text)
            if new != text:
                path.write_text(new, encoding="utf-8")
    # Deepest paths first so parents are renamed after their children.
    for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        rel = path.relative_to(root).as_posix()
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts) or _allowed(rel):
            continue
        new_name = rewrite(path.name)
        if new_name != path.name:
            path.rename(path.with_name(new_name))


def leftovers(root: Path) -> list[str]:
    found = []
    for path, rel in _files(root):
        if _allowed(rel):
            continue
        if "palmier" in rel.lower():
            found.append(f"{rel}: path")
        text = _read_text(path)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if "palmier" in line.lower() and ALLOW_MARKER not in line:
                found.append(f"{rel}:{number}: {line.strip()[:120]}")
    return found


def vendor_leftovers(root: Path) -> list[str]:
    found = []
    for path, rel in _files(root):
        if _allowed(rel):
            continue
        text = _read_text(path)
        if text is None:
            continue
        is_manifest = path.name in {"Package.swift", "Package.resolved"}
        for number, line in enumerate(text.splitlines(), 1):
            if (path.suffix == ".swift" and VENDOR_IMPORT.match(line)) or (
                is_manifest and VENDOR_PACKAGE.search(line)
            ):
                found.append(f"{rel}:{number}: {line.strip()[:120]}")
    return found


def main(argv: list[str]) -> int:
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parent.parent
    if "--check" in flags or "--check-vendors" in flags:
        found = (leftovers(root) if "--check" in flags else []) + (
            vendor_leftovers(root) if "--check-vendors" in flags else []
        )
        print("\n".join(found))
        return 1 if found else 0
    run(root)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
