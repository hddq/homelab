#!/usr/bin/env python3
"""Validates that all Kubernetes namespaces with PersistentVolumeClaims (PVCs)
are either included in K8up backup schedules or explicitly excluded.
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


@dataclass
class PVCInfo:
    name: str
    namespace: str
    source: str
    is_nfs: bool = False
    explicitly_excluded: bool = False


@dataclass
class ScanResult:
    included_namespaces: set[str] = field(default_factory=set)
    excluded_namespaces: set[str] = field(default_factory=set)
    nfs_pvs: set[str] = field(default_factory=set)
    all_pvcs: list[PVCInfo] = field(default_factory=list)


def parse_k8up_values(values_path: Path) -> tuple[set[str], set[str]]:
    """Reads includeNamespaces and excludeNamespaces from k8up-backups values.yaml."""
    if not values_path.exists():
        print(f"Error: K8up values file not found at {values_path}", file=sys.stderr)
        sys.exit(1)

    with values_path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    include_ns = set(data.get("includeNamespaces") or [])
    exclude_ns = set(data.get("excludeNamespaces") or [])
    return include_ns, exclude_ns


def build_app_namespace_map(repo_root: Path) -> dict[Path, str]:
    """Maps application/infra directories to their target namespace from bootstrap manifests."""
    ns_map: dict[Path, str] = {}
    bootstrap_files = [
        repo_root / "kubernetes/clusters/homelab/bootstrap/templates/apps.yaml",
        repo_root
        / "kubernetes/clusters/homelab/bootstrap/templates/infrastructure.yaml",
    ]

    for bf in bootstrap_files:
        if not bf.exists():
            continue
        matches = re.findall(
            r'"path"\s+"([^"]+)"\s+"namespace"\s+"([^"]+)"',
            bf.read_text(encoding="utf-8"),
        )
        for path_str, ns in matches:
            ns_map[(repo_root / path_str).resolve()] = ns

    return ns_map


def resolve_namespace(
    target: Path, ns_map: dict[Path, str], repo_root: Path
) -> str | None:
    """Resolves namespace from directory path or ancestor kustomization.yaml."""
    curr = target if target.is_dir() else target.parent
    while curr != repo_root and curr != curr.parent:
        if curr in ns_map:
            return ns_map[curr]

        kust = curr / "kustomization.yaml"
        if kust.exists():
            try:
                for doc in yaml.safe_load_all(kust.read_text(encoding="utf-8")):
                    if isinstance(doc, dict) and doc.get("namespace"):
                        return str(doc["namespace"])
            except (yaml.YAMLError, OSError) as e:
                logger.debug("Failed reading %s: %s", kust, e)

        curr = curr.parent
    return None


def scan_manifest_docs(
    docs: list[Any],
    source_desc: str,
    default_ns: str | None,
    nfs_pvs: set[str],
) -> list[PVCInfo]:
    """Extracts PVCs and NFS PVs from parsed YAML documents."""
    pvcs: list[PVCInfo] = []

    # First pass: collect PersistentVolumes with NFS specs
    for doc in docs:
        if isinstance(doc, dict) and doc.get("kind") == "PersistentVolume":
            meta = doc.get("metadata") or {}
            pv_name = meta.get("name")
            spec = doc.get("spec") or {}
            if pv_name and "nfs" in spec:
                nfs_pvs.add(pv_name)

    # Second pass: collect PVCs and StatefulSet volumeClaimTemplates
    for doc in docs:
        if not isinstance(doc, dict):
            continue

        kind = doc.get("kind")
        if kind == "PersistentVolumeClaim":
            meta = doc.get("metadata") or {}
            name = meta.get("name") or "unnamed"
            ns = meta.get("namespace") or default_ns or "default"
            annotations = meta.get("annotations") or {}
            backup_val = str(annotations.get("k8up.io/backup", "true")).strip().lower()
            spec = doc.get("spec") or {}
            volume_name = spec.get("volumeName")
            storage_class = spec.get("storageClassName")

            is_nfs = (
                (bool(volume_name) and volume_name in nfs_pvs)
                or "nfs" in str(storage_class).lower()
                or "nfs" in name.lower()
            )

            pvcs.append(
                PVCInfo(
                    name=name,
                    namespace=ns,
                    source=source_desc,
                    is_nfs=is_nfs,
                    explicitly_excluded=(backup_val == "false"),
                )
            )

        elif kind == "StatefulSet":
            meta = doc.get("metadata") or {}
            ss_ns = meta.get("namespace") or default_ns or "default"
            spec = doc.get("spec") or {}
            vcts = spec.get("volumeClaimTemplates") or []
            for vct in vcts:
                vct_meta = vct.get("metadata") or {}
                name = vct_meta.get("name") or "unnamed"
                annotations = vct_meta.get("annotations") or {}
                backup_val = (
                    str(annotations.get("k8up.io/backup", "true")).strip().lower()
                )

                pvcs.append(
                    PVCInfo(
                        name=name,
                        namespace=ss_ns,
                        source=f"{source_desc} (StatefulSet: {meta.get('name', 'unnamed')})",
                        is_nfs=False,
                        explicitly_excluded=(backup_val == "false"),
                    )
                )

    return pvcs


def scan_paths(
    targets: list[Path],
    k8up_values_path: Path,
    repo_root: Path,
) -> ScanResult:
    """Scans target files/directories for PVCs."""
    include_ns, exclude_ns = parse_k8up_values(k8up_values_path)
    ns_map = build_app_namespace_map(repo_root)

    result = ScanResult(
        included_namespaces=include_ns,
        excluded_namespaces=exclude_ns,
    )

    yaml_files: list[Path] = []
    for target in targets:
        if not target.exists():
            continue
        if target.is_file() and target.suffix in (".yaml", ".yml"):
            yaml_files.append(target)
        elif target.is_dir():
            for p in target.rglob("*"):
                if p.is_file() and p.suffix in (".yaml", ".yml"):
                    yaml_files.append(p)

    for y_path in sorted(yaml_files):
        try:
            content = y_path.read_text(encoding="utf-8")
        except OSError as e:
            logger.debug("Failed reading %s: %s", y_path, e)
            continue

        if (
            "PersistentVolumeClaim" not in content
            and "volumeClaimTemplates" not in content
            and "PersistentVolume" not in content
        ):
            continue

        try:
            docs = list(yaml.safe_load_all(content))
        except yaml.YAMLError as e:
            logger.debug("YAML load error in %s: %s", y_path, e)
            continue

        default_ns = resolve_namespace(y_path, ns_map, repo_root)
        rel_source = (
            str(y_path.relative_to(repo_root))
            if y_path.is_relative_to(repo_root)
            else str(y_path)
        )
        pvcs = scan_manifest_docs(docs, rel_source, default_ns, result.nfs_pvs)
        result.all_pvcs.extend(pvcs)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify all Kubernetes PVC namespaces are covered by K8up backups or explicitly excluded."
    )
    parser.add_argument(
        "targets",
        nargs="*",
        type=Path,
        default=[
            Path("kubernetes/clusters/homelab/apps"),
            Path(".ci/rendered"),
        ],
        help="Paths to manifest directories or rendered files to scan (default: apps/ and .ci/rendered)",
    )
    parser.add_argument(
        "--k8up-values",
        type=Path,
        default=Path("kubernetes/clusters/homelab/infra/k8up-backups/values.yaml"),
        help="Path to k8up-backups values.yaml",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable verbose logging"
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    k8up_values = (repo_root / args.k8up_values).resolve()
    target_paths = [(repo_root / p).resolve() for p in args.targets]

    result = scan_paths(target_paths, k8up_values, repo_root)

    # Group PVCs by namespace
    ns_pvcs: dict[str, list[PVCInfo]] = {}
    for pvc in result.all_pvcs:
        ns_pvcs.setdefault(pvc.namespace, []).append(pvc)

    violations: dict[str, list[PVCInfo]] = {}
    covered_pvcs_count = 0
    excluded_pvcs_count = 0

    for ns, pvcs in sorted(ns_pvcs.items()):
        uncovered_in_ns = []
        for pvc in pvcs:
            if pvc.explicitly_excluded:
                excluded_pvcs_count += 1
                if args.verbose:
                    print(
                        f"  [EXCLUDED] PVC {pvc.name} in {ns} (k8up.io/backup: false)"
                    )
            elif pvc.is_nfs:
                excluded_pvcs_count += 1
                if args.verbose:
                    print(f"  [EXCLUDED] PVC {pvc.name} in {ns} (NFS Volume)")
            elif ns in result.excluded_namespaces:
                excluded_pvcs_count += 1
                if args.verbose:
                    print(
                        f"  [EXCLUDED] PVC {pvc.name} in {ns} (namespace in excludeNamespaces)"
                    )
            elif ns in result.included_namespaces:
                covered_pvcs_count += 1
                if args.verbose:
                    print(f"  [COVERED]  PVC {pvc.name} in {ns} (backed up by K8up)")
            else:
                uncovered_in_ns.append(pvc)

        if uncovered_in_ns:
            violations[ns] = uncovered_in_ns

    if violations:
        print("=" * 72, file=sys.stderr)
        print("❌ K8up Backup Coverage Check FAILED!", file=sys.stderr)
        print("=" * 72, file=sys.stderr)
        print(
            "The following namespaces contain PersistentVolumeClaims but are NOT covered",
            file=sys.stderr,
        )
        print(
            f"by K8up backup schedules in {k8up_values.relative_to(repo_root)}:\n",
            file=sys.stderr,
        )

        for ns, pvcs in sorted(violations.items()):
            print(f"  Namespace: {ns}", file=sys.stderr)
            for pvc in pvcs:
                print(f"    - PVC: {pvc.name} ({pvc.source})", file=sys.stderr)
            print(file=sys.stderr)

        print("How to fix this:", file=sys.stderr)
        print(
            f"  1. If these PVCs SHOULD be backed up:\n"
            f"     Add the namespace to 'includeNamespaces' in:\n"
            f"     {k8up_values.relative_to(repo_root)}\n",
            file=sys.stderr,
        )
        print(
            "  2. If individual PVCs should NOT be backed up (e.g. caches, temporary data):\n"
            "     Annotate the PVC metadata with:\n"
            "       metadata:\n"
            "         annotations:\n"
            '           k8up.io/backup: "false"\n',
            file=sys.stderr,
        )
        print(
            f"  3. If the entire namespace is backed up through alternative means\n"
            f"     (e.g. CloudNative-PG Barman plugin, TrueNAS ZFS snapshots):\n"
            f"     Add the namespace to 'excludeNamespaces' in:\n"
            f"     {k8up_values.relative_to(repo_root)}\n",
            file=sys.stderr,
        )
        print("=" * 72, file=sys.stderr)
        return 1

    print(
        f"✅ K8up backup check passed: {len(result.included_namespaces)} covered namespaces, "
        f"{covered_pvcs_count} PVCs backed up, {excluded_pvcs_count} PVCs safely excluded."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
