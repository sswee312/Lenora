import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import rebrand  # noqa: E402


@pytest.mark.parametrize(
    ("before", "after"),
    [
        ("io.palmier.pro", "xyz.agentage.lenora"),
        ("io.palmier.project", "xyz.agentage.lenora.project"),
        ("palmier://callback", "lenora://callback"),
        ("Untitled.palmier", "Untitled.lenora"),
        ("github.com/palmier-io/palmier-skills", "github.com/vermatushar/lenora-skills"),
        ("import PalmierPro", "import Lenora"),
        ("palmier-pro.mcpb", "lenora.mcpb"),
        ("https://palmier.pro/docs", "https://lenora/docs"),
        ("https://palmier.io/docs", "https://github.com/vermatushar/lenora#readme"),
        ("[Palmier](https://palmier.io)", "[Lenora](https://github.com/vermatushar/lenora)"),
        ("PalmierProjectExporter", "LenoraProjectExporter"),
        ("PALMIER_TOKEN", "LENORA_TOKEN"),
        ("Palmier and palmier", "Lenora and lenora"),
    ],
)
def test_rewrite_text(before, after):
    assert rebrand.rewrite(before) == after


def test_allow_marker_lines_are_kept():
    text = "Based on Palmier Pro. <!-- rebrand:allow -->\nPalmier\n"
    assert rebrand.rewrite_lines(text) == "Based on Palmier Pro. <!-- rebrand:allow -->\nLenora\n"


def test_rebrand_renames_paths_and_check_passes(tmp_path):
    src = tmp_path / "app/Sources/PalmierPro"
    src.mkdir(parents=True)
    (src / "PalmierApp.swift").write_text("struct PalmierApp {}\n")
    (tmp_path / "NOTICE").write_text("Palmier Pro\n")
    (tmp_path / "docs/research").mkdir(parents=True)
    (tmp_path / "docs/research/r.md").write_text("palmier\n")
    (tmp_path / "logo.png").write_bytes(b"\x89PNG\x00palmier")

    rebrand.run(tmp_path)

    moved = tmp_path / "app/Sources/Lenora/LenoraApp.swift"
    assert moved.read_text() == "struct LenoraApp {}\n"
    assert (tmp_path / "NOTICE").read_text() == "Palmier Pro\n"
    assert (tmp_path / "docs/research/r.md").read_text() == "palmier\n"
    assert rebrand.leftovers(tmp_path) == []


@pytest.mark.parametrize("scratch", [".superpowers", ".pytest_cache"])
def test_leftovers_skip_ignored_scratch(tmp_path, scratch):
    (tmp_path / scratch / "sub").mkdir(parents=True)
    (tmp_path / scratch / "sub" / "note.md").write_text("palmier\n")
    assert rebrand.leftovers(tmp_path) == []


def test_check_reports_leftovers(tmp_path):
    (tmp_path / "a.txt").write_text("palmier\n")
    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "rebrand.py"), "--check", str(tmp_path)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "a.txt:1" in result.stdout


def test_check_vendors(tmp_path):
    (tmp_path / "app/Sources/X").mkdir(parents=True)
    (tmp_path / "app/Sources/X/A.swift").write_text("import Sparkle\nlet icon = \"sparkles\"\n")
    assert rebrand.vendor_leftovers(tmp_path) == ["app/Sources/X/A.swift:1: import Sparkle"]
