#!/usr/bin/env bash

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR

# shellcheck source=lib/cache.sh
source "$LIB_DIR/cache.sh"

# shellcheck source=lib/providers/gcp.sh
source "$LIB_DIR/providers/gcp.sh"

generate_inventory() {
  local generated_at projects

  generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" || return 1
  projects="$(jq -cn --args '$ARGS.positional' -- "${GCP_PROJECTS[@]}")" || return 1

  sync_gcp | jq -s \
    --arg generated_at "$generated_at" \
    --argjson projects "$projects" '
    {
      version: 1,
      generated_at: $generated_at,
      scope: {gcp: {projects: $projects}},
      resources: (
        reduce .[] as $entry ({};
          reduce ($entry | to_entries[]) as $item (.;
            .[$item.key] = ((.[$item.key] // []) + $item.value)
          )
        )
      )
    }
  ' || return 1
}

sync() {
  local cache_file cache_dir tmp_file saved_traps
  local status=0

  cache_file="$(cache_file_path)" || return 1
  cache_dir="${cache_file%/*}"
  (umask 077; mkdir -p -- "$cache_dir") || return 1
  tmp_file="$(mktemp "$cache_dir/.cache.XXXXXX")" || return 1

  # Catch signals in the calling shell so cancellation cannot publish a later result.
  saved_traps="$(trap -p INT TERM)"
  trap 'rm -f -- "$tmp_file"; exit 130' INT
  trap 'rm -f -- "$tmp_file"; exit 143' TERM

  if ! generate_inventory >"$tmp_file"; then
    printf 'Error: inventory collection failed; cache was not replaced.\n' >&2
    status=1
  elif ! load_cache "$tmp_file" >/dev/null; then
    printf 'Error: invalid inventory; cache was not replaced.\n' >&2
    status=1
  # Refuse directories: mv would otherwise move the temporary file inside one.
  elif [[ -d "$cache_file" ]] || ! mv -f -- "$tmp_file" "$cache_file"; then
    printf 'Error: could not replace cache at %s.\n' "$cache_file" >&2
    status=1
  else
    printf 'Cache written to %s\n' "$cache_file" >&2
  fi

  rm -f -- "$tmp_file" || status=1
  trap - INT TERM
  # Restore only trap definitions captured from this shell, never configuration input.
  eval "$saved_traps"
  return "$status"
}
