#!/usr/bin/env python3
"""Include notices for the Swift app and router shipped by Turnrail."""

import argparse
import shutil
from pathlib import Path

from project_metadata import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    output = parser.parse_args().output
    output.mkdir(parents=True, exist_ok=False)
    for source in ("LICENSE", "NOTICE"):
        shutil.copyfile(ROOT / source, output / f"Turnrail-{source}.txt")
    (output / "Runtime.txt").write_text(
        "Codex Turnrail uses the separately installed ChatGPT app and its "
        "unmodified, OpenAI-signed Engine. No OpenAI executable is redistributed "
        "in this app. The Swift app and router use macOS system frameworks.\n"
    )


if __name__ == "__main__":
    main()
