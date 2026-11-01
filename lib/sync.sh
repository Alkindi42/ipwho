#!/usr/bin/env bash

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR

# shellcheck source=lib/providers/gcp.sh
source "$LIB_DIR/providers/gcp.sh"

sync() {
  local generated_at

  generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  {
    sync_gcp
  } | jq -s --arg generated_at "$generated_at" '
    {
      generated_at: $generated_at,
      resources: (
        reduce .[] as $entry ({};
          reduce ($entry | to_entries[]) as $item (.;
            .[$item.key] = ((.[$item.key] // []) + $item.value)
          )
        )
      )
    }
  '
}
