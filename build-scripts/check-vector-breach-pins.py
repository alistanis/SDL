#!/usr/bin/env python3
"""Check that all native Vector Breach consumers stage the same shared SDL."""
import argparse
from pathlib import Path
import subprocess
import sys

GAMES = ("VectorBreach-Accelerando", "VectorBreach-Afterglow", "VectorBreach-Counterpoint")


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], text=True).strip()


def main():
    source = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=source.parent,
                        help="directory containing the three game checkouts")
    parser.add_argument("--revision", default=git(source, "rev-parse", "HEAD"))
    args = parser.parse_args()
    failures = []
    for name in GAMES:
        game = args.root / name
        try:
            entry = git(game, "ls-files", "--stage", "third_party/SDL").split()
            if len(entry) != 4 or entry[0] != "160000" or entry[1] != args.revision or entry[2] != "0":
                raise ValueError("staged SDL gitlink does not match " + args.revision)
            url = git(game, "config", "-f", ".gitmodules", "--get", "submodule.third_party/SDL.url")
            if url != "https://github.com/alistanis/SDL.git":
                raise ValueError("unexpected SDL fork URL: " + url)
            checkout = game / "third_party/SDL"
            if git(checkout, "rev-parse", "HEAD") != args.revision:
                raise ValueError("SDL working checkout differs from the staged pin")
            if git(checkout, "status", "--porcelain", "--untracked-files=normal"):
                raise ValueError("SDL working checkout has local changes")
            print(name + ": " + args.revision)
        except (OSError, subprocess.CalledProcessError, ValueError) as error:
            failures.append(name + ": " + str(error))
    for failure in failures:
        print(failure, file=sys.stderr)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
