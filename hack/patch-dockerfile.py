#!/usr/bin/env python3
"""Rewrite openperouter's Dockerfile.grout to install locally provided grout RPMs.

Upstream downloads the grout/frr RPMs from a pinned GitHub release. This
replaces that single RUN instruction with a COPY of the RPMs built by a given
grout commit, so the image tests grout main instead of the release.

Fails loudly if the Dockerfile no longer has exactly one such instruction: that
means openperouter changed how it consumes grout and this script needs updating.
"""

import argparse
import pathlib
import shutil
import sys

RELEASE_URL_MARKER = "github.com/DPDK/grout/releases/download"
# The packages upstream installs; debuginfo/headers RPMs are left out.
PACKAGES = ("frr", "grout-frr", "grout")
RPM_DIR_IN_CONTEXT = ".grout-rpms"


def logical_instructions(lines):
    """Group physical lines into Dockerfile instructions (backslash continuations)."""
    start = None
    for i, line in enumerate(lines):
        if start is None:
            start = i
        if not line.rstrip("\n").endswith("\\"):
            yield start, i + 1
            start = None
    if start is not None:
        yield start, len(lines)


def find_rpm(rpm_dir, package, arch):
    # Exact name match: "frr.*.rpm" must not pick up "frr-headers.noarch.rpm".
    path = rpm_dir / f"{package}.{arch}.rpm"
    if not path.is_file():
        sys.exit(f"error: {path} not found in grout artifacts")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True, type=pathlib.Path,
                        help="openperouter checkout (docker build context)")
    parser.add_argument("--dockerfile", default="Dockerfile.grout",
                        help="Dockerfile path relative to the context")
    parser.add_argument("--rpms", required=True, type=pathlib.Path,
                        help="directory holding the grout RPM artifacts")
    parser.add_argument("--arch", default="x86_64")
    args = parser.parse_args()

    dockerfile = args.context / args.dockerfile
    lines = dockerfile.read_text().splitlines(keepends=True)

    matches = [(s, e) for s, e in logical_instructions(lines)
               if RELEASE_URL_MARKER in "".join(lines[s:e])]
    if len(matches) != 1:
        sys.exit(f"error: expected exactly one instruction referencing "
                 f"{RELEASE_URL_MARKER} in {dockerfile}, found {len(matches)}")
    start, end = matches[0]
    if not lines[start].lstrip().upper().startswith("RUN"):
        sys.exit(f"error: grout release reference at line {start + 1} is not a RUN instruction")

    dest = args.context / RPM_DIR_IN_CONTEXT
    dest.mkdir(exist_ok=True)
    for package in PACKAGES:
        shutil.copy2(find_rpm(args.rpms, package, args.arch), dest)

    replacement = [
        "# Patched by grout-openperouter: install RPMs built from grout main.\n",
        f"COPY {RPM_DIR_IN_CONTEXT}/ /tmp/grout-rpms/\n",
        "RUN dnf install -y /tmp/grout-rpms/*.rpm && dnf clean all && rm -rf /tmp/grout-rpms\n",
    ]
    print(f"Replacing {dockerfile} lines {start + 1}-{end}:")
    print("".join(lines[start:end]), end="")
    print("with:")
    print("".join(replacement), end="")

    lines[start:end] = replacement
    dockerfile.write_text("".join(lines))


if __name__ == "__main__":
    main()
