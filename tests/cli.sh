#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/config"
export XDG_CACHE_HOME="$tmp_dir/cache"
cache_file="$XDG_CACHE_HOME/ipwho/cache.json"
export IPWHO_TEST_CALLS="$tmp_dir/calls"
export IPWHO_TEST_SOURCED="$tmp_dir/sourced"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/gcp"
# Expanded only when the generated fixture is sourced by the adapter.
# shellcheck disable=SC2016
printf '%s\n' \
  'printf "sourced\n" >> "$IPWHO_TEST_SOURCED"' \
  'GCP_PROJECTS=(shared-a shared-b)' \
  >"$XDG_CONFIG_HOME/gcp/projects.bash"

# Export the mock so CLI subprocesses never invoke the real gcloud command.
gcloud() {
  printf '%s\n' "$*" >>"$IPWHO_TEST_CALLS"
  case "$1 $2 $3" in
  'compute routers list') printf '[]\n' ;;
  'compute forwarding-rules list') printf '[]\n' ;;
  'compute instances list')
    if [[ "${IPWHO_TEST_FAIL_COMPUTE:-0}" -eq 1 ]]; then
      printf 'Mock Compute API failure\n' >&2
      return 1
    fi
    local project="${4#--project=}"
    jq -cn --arg name "$project-vm" '[{
      name: $name,
      id: "1",
      zone: "europe-west1-b",
      status: "RUNNING",
      networkInterfaces: [{name: "nic0", accessConfigs: [{natIP: "203.0.113.10"}]}]
    }]'
    ;;
  *) printf 'Unexpected gcloud call: %s\n' "$*" >&2; return 1 ;;
  esac
}
export -f gcloud

run() {
  local expected="$1"
  local status=0
  shift
  : >"$IPWHO_TEST_CALLS"
  "$@" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr" || status=$?
  if [[ "$status" -ne "$expected" ]]; then
    printf 'FAIL: expected exit %s, got %s: %s\n' "$expected" "$status" "$*" >&2
    exit 1
  fi
}

run_cli() {
  local expected="$1"
  shift
  run "$expected" "$BASH" "$ROOT_DIR/ipwho" "$@"
}

expect_usage_error() {
  run_cli 2 "$@"
  [[ ! -s "$tmp_dir/stdout" && -s "$tmp_dir/stderr" && ! -s "$IPWHO_TEST_CALLS" ]]
}

run_cli 0 --help
[[ -s "$tmp_dir/stdout" && ! -s "$tmp_dir/stderr" && ! -s "$IPWHO_TEST_CALLS" ]]
grep -q -- '--gcp-project' "$tmp_dir/stdout"
run_cli 0 -h
[[ ! -s "$IPWHO_TEST_CALLS" ]]
run_cli 0 sync --help
[[ ! -s "$IPWHO_TEST_CALLS" ]]
printf 'PASS: help needs no project configuration or cloud access\n'

expect_usage_error
expect_usage_error sync
expect_usage_error sync --gcp-project
expect_usage_error sync --gcp-project ''
expect_usage_error sync --gcp-project '   '
expect_usage_error sync --gcp-project 'project with spaces'
expect_usage_error sync --gcp-project $'project\nother-project'
expect_usage_error sync --gcp-project --help
expect_usage_error sync --unknown
expect_usage_error sync --gcp-project first-project --unknown
expect_usage_error --unknown
expect_usage_error 203.0.113.10 extra-argument
printf 'PASS: invalid arguments fail before collection, with errors on stderr\n'

export GCP_PROJECTS='legacy-project'
export CLOUDSDK_CORE_PROJECT='active-project'
expect_usage_error sync
unset GCP_PROJECTS CLOUDSDK_CORE_PROJECT
printf 'PASS: projects are never selected implicitly from the environment\n'

run_cli 0 sync --gcp-project first-project --gcp-project second-project --gcp-project first-project
jq empty "$cache_file"
jq -e '
  .version == 1 and
  .scope.gcp.projects == ["first-project", "second-project"] and
  [.resources["203.0.113.10"][].project] == ["first-project", "second-project"]
' "$cache_file" >/dev/null
[[ $(wc -l <"$IPWHO_TEST_CALLS") -eq 6 && ! -s "$tmp_dir/stdout" && -s "$tmp_dir/stderr" ]]
printf 'PASS: explicit projects are collected once, in first-occurrence order\n'

cp "$cache_file" "$tmp_dir/previous-cache"
export IPWHO_TEST_FAIL_COMPUTE=1
run_cli 1 sync --gcp-project first-project --gcp-project second-project
[[ ! -s "$tmp_dir/stdout" && -s "$tmp_dir/stderr" && $(wc -l <"$IPWHO_TEST_CALLS") -eq 3 ]]
cmp -s "$cache_file" "$tmp_dir/previous-cache"
unset IPWHO_TEST_FAIL_COMPUTE
printf 'PASS: collection failures remain nonzero and stop before the next project\n'

run_cli 0 203.0.113.10
[[ ! -s "$IPWHO_TEST_CALLS" && ! -s "$tmp_dir/stderr" ]]
[[ ! -e "$IPWHO_TEST_SOURCED" ]]
printf 'PASS: ipwho never sources the personal project file, including for lookup\n'

run 0 env PATH="$ROOT_DIR:$PATH" "$BASH" "$ROOT_DIR/examples/ipwho-sync.sh"
jq -e '
  [.resources["203.0.113.10"][].project] == ["shared-a", "shared-b"]
' "$cache_file" >/dev/null
[[ -s "$IPWHO_TEST_SOURCED" && ! -s "$tmp_dir/stdout" && -s "$tmp_dir/stderr" ]]
printf 'PASS: the adapter uses the existing shared project list\n'

mkdir -p "$HOME/.config/gcp"
printf 'GCP_PROJECTS=(fallback-project)\n' >"$HOME/.config/gcp/projects.bash"
run 0 env -u XDG_CONFIG_HOME PATH="$ROOT_DIR:$PATH" "$BASH" "$ROOT_DIR/examples/ipwho-sync.sh"
jq -e '
  [.resources["203.0.113.10"][].project] == ["fallback-project"]
' "$cache_file" >/dev/null
printf 'PASS: the adapter falls back to HOME/.config when XDG_CONFIG_HOME is unset\n'

printf 'GCP_PROJECTS=()\n' >"$XDG_CONFIG_HOME/gcp/projects.bash"
run 1 env PATH="$ROOT_DIR:$PATH" "$BASH" "$ROOT_DIR/examples/ipwho-sync.sh"
[[ ! -s "$tmp_dir/stdout" && -s "$tmp_dir/stderr" && ! -s "$IPWHO_TEST_CALLS" ]]
printf 'PASS: an empty shared list fails without starting collection\n'
