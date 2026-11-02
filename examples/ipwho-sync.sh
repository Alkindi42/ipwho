#!/usr/bin/env bash

set -euo pipefail

GCP_PROJECTS=()

# shellcheck source=/dev/null
source "${XDG_CONFIG_HOME:-$HOME/.config}/gcp/projects.bash"

if [[ ${#GCP_PROJECTS[@]} -eq 0 ]]; then
  printf 'Error: no GCP projects configured in projects.bash.\n' >&2
  exit 1
fi

args=()
for project in "${GCP_PROJECTS[@]}"; do
  args+=(--gcp-project "$project")
done

exec ipwho sync "${args[@]}" "$@"
