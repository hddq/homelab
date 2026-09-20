#!/usr/bin/env python3
"""Updates the talosctl package sha256 hash in flake.nix based on official release checksums."""

from __future__ import annotations

import argparse
import base64
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

TALOSCTL_PATTERN = re.compile(
    r"(talosctl\s*=\s*pkgs\.stdenv\.mkDerivation\s*rec\s*\{.*?"
    r'pname\s*=\s*"talosctl";.*?'
    r'version\s*=\s*"(?P<version>[^"]+)";.*?'
    r"src\s*=\s*pkgs\.fetchurl\s*\{.*?"
    r'hash\s*=\s*")(?P<hash>[^"]+)(";)',
    re.DOTALL,
)


def set_github_output(name: str, value: str) -> None:
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(f"{name}={value}\n")


def get_expected_sri_hash(version: str) -> str:
    # Ensure version format for release tag
    clean_version = version.lstrip("v")
    url = f"https://github.com/siderolabs/talos/releases/download/v{clean_version}/sha256sum.txt"

    req = urllib.request.Request(
        url,
        headers={"User-Agent": "gitops-ci-talosctl-hasher"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read().decode("utf-8")
    except urllib.error.URLError as err:
        raise RuntimeError(f"Failed to fetch checksums from {url}: {err}") from err

    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].strip() == "talosctl-linux-amd64":
            hex_digest = parts[0].strip()
            return (
                f"sha256-{base64.b64encode(bytes.fromhex(hex_digest)).decode('utf-8')}"
            )

    raise ValueError(f"talosctl-linux-amd64 entry not found in checksums from {url}")


def update_talosctl_hash(flake_path: Path) -> bool:
    if not flake_path.is_file():
        raise FileNotFoundError(f"Flake file not found: {flake_path}")

    content = flake_path.read_text(encoding="utf-8")
    match = TALOSCTL_PATTERN.search(content)
    if not match:
        raise ValueError(f"Could not find talosctl derivation in {flake_path}")

    version = match.group("version")
    current_hash = match.group("hash")

    expected_hash = get_expected_sri_hash(version)

    if current_hash == expected_hash:
        print(f"talosctl (v{version}) hash is already up to date: {current_hash}")
        set_github_output("updated", "false")
        set_github_output("version", version)
        set_github_output("hash", expected_hash)
        return False

    print(f"Updating talosctl (v{version}) hash:")
    print(f"  Old: {current_hash}")
    print(f"  New: {expected_hash}")

    hash_span = match.span("hash")
    new_content = content[: hash_span[0]] + expected_hash + content[hash_span[1] :]
    flake_path.write_text(new_content, encoding="utf-8")

    set_github_output("updated", "true")
    set_github_output("version", version)
    set_github_output("hash", expected_hash)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--flake-path",
        type=Path,
        default=Path("flake.nix"),
        help="Path to flake.nix (default: flake.nix)",
    )
    args = parser.parse_args()

    try:
        update_talosctl_hash(args.flake_path)
    except (urllib.error.URLError, ValueError, OSError) as err:
        print(f"Error: {err}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
