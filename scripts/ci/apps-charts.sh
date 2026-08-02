#!/usr/bin/env bash

set -euo pipefail

list_charts() {
  find kubernetes/clusters/homelab/apps -name Chart.yaml -not -path '*/charts/*' -print \
    | sort \
    | while IFS= read -r chart_file; do
        dirname "$chart_file"
      done
}

chart_id() {
  local chart_dir=$1
  local id=${chart_dir#kubernetes/clusters/homelab/apps/}
  printf '%s\n' "${id//\//-}"
}

list_repos() {
  while IFS= read -r chart_dir; do
    awk '/repository:/ { print $2 }' "$chart_dir/Chart.yaml"
  done < <(list_charts) | sort -u | grep -v '^oci://' || true
}

build_deps() {
  mapfile -t repos < <(list_repos)

  for i in "${!repos[@]}"; do
    helm repo add "apps-repo-$i" "${repos[$i]}"
  done

  if [ "${#repos[@]}" -gt 0 ]; then
    helm repo update
  fi

  while IFS= read -r chart_dir; do
    echo "Building dependencies for $chart_dir"
    helm dependency build "$chart_dir"
  done < <(list_charts)
}

render_charts() {
  local outdir=${1:-.ci/rendered/infrastructure}

  mkdir -p "$outdir"

  while IFS= read -r chart_dir; do
    local id
    local release
    id=$(chart_id "$chart_dir")
    release="apps-$id"

    for env in staging production; do
      args=()
      if [ -f "$chart_dir/values.yaml" ]; then
        args+=(-f "$chart_dir/values.yaml")
      fi
      if [ -f "$chart_dir/values-$env.yaml" ]; then
        args+=(-f "$chart_dir/values-$env.yaml")
      fi

      echo "Rendering $id for $env environment"
      helm template "$release" "$chart_dir" "${args[@]}" \
        > "$outdir/$id-$env.yaml"
    done
  done < <(list_charts)
}

lint_charts() {
  while IFS= read -r chart_dir; do
    echo "Linting $chart_dir"
    helm lint "$chart_dir"
  done < <(list_charts)
}

usage() {
  cat <<'EOF'
Usage:
  scripts/ci/apps-charts.sh list
  scripts/ci/apps-charts.sh build-deps
  scripts/ci/apps-charts.sh render [output_dir]
  scripts/ci/apps-charts.sh lint
EOF
}

main() {
  local command=${1:-}

  case "$command" in
    list)
      list_charts
      ;;
    build-deps)
      build_deps
      ;;
    render)
      render_charts "${2:-.ci/rendered/infrastructure}"
      ;;
    lint)
      lint_charts
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
