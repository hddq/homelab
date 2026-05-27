#!/usr/bin/env bash

set -euo pipefail

is_sops_file() {
  local file=$1

  grep -qm1 '^sops:' "$file"
}

find_yaml_files() {
  find "$@" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort
}

main() {
  local file

  while IFS= read -r file; do
    if is_sops_file "$file"; then
      continue
    fi

    printf '%s\n' "$file"
  done < <(find_yaml_files "$@")
}

main "$@"
