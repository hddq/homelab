#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/ci/helm-charts.sh <directory> list
  scripts/ci/helm-charts.sh <directory> build-deps
  scripts/ci/helm-charts.sh <directory> render [output_dir]
  scripts/ci/helm-charts.sh <directory> lint
EOF
}

if [ $# -lt 2 ]; then
  usage >&2
  exit 1
fi

BASE_DIR=${1%/}
COMMAND=$2
TYPE=$(basename "$BASE_DIR")
OUTDIR=${3:-.ci/rendered/${TYPE}}

list_charts() {
  find "$BASE_DIR" -name Chart.yaml -not -path '*/charts/*' -print \
    | sort \
    | while IFS= read -r chart_file; do
        dirname "$chart_file"
      done
}

chart_id() {
  local chart_dir=$1
  local id=${chart_dir#"${BASE_DIR}"/}
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
    helm repo add "${TYPE}-repo-$i" "${repos[$i]}"
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
  local outdir=${1:-$OUTDIR}

  mkdir -p "$outdir"

  while IFS= read -r chart_dir; do
    local id
    local release
    id=$(chart_id "$chart_dir")
    release="${TYPE}-$id"

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

case "$COMMAND" in
  list)
    list_charts
    ;;
  build-deps)
    build_deps
    ;;
  render)
    if [ -n "${3:-}" ]; then
      render_charts "$3"
    else
      render_charts "$OUTDIR"
    fi
    ;;
  lint)
    lint_charts
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
