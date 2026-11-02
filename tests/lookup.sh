#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

lookup_test_dir="$(mktemp -d)"
trap 'rm -rf "$lookup_test_dir"' EXIT
export HOME="$lookup_test_dir/home"
export XDG_CONFIG_HOME="$lookup_test_dir/config"
export XDG_CACHE_HOME="$lookup_test_dir/cache with spaces"
export IPWHO_TEST_CACHE="$XDG_CACHE_HOME/ipwho/cache.json"
export IPWHO_TEST_CLOUD_CALLS="$lookup_test_dir/cloud-calls"
export IPWHO_TEST_PROJECTS_SOURCED="$lookup_test_dir/projects-sourced"
export IPWHO_TEST_REPLACEMENT="$lookup_test_dir/replacement.json"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/gcp"
# Expanded only if the CLI incorrectly sources the personal project file.
# shellcheck disable=SC2016
printf 'touch "$IPWHO_TEST_PROJECTS_SOURCED"\n' >"$XDG_CONFIG_HOME/gcp/projects.bash"

# Any cloud request is a test failure; no real gcloud command is ever invoked.
gcloud() {
  printf '%s\n' "$*" >>"$IPWHO_TEST_CLOUD_CALLS"
  return 99
}
export -f gcloud

run() {
  local expected="$1"
  local status=0
  shift
  "$@" >"$lookup_test_dir/stdout" 2>"$lookup_test_dir/stderr" || status=$?
  if [[ "$status" -ne "$expected" ]]; then
    printf 'FAIL: expected exit %s, got %s: %s\n' "$expected" "$status" "$*" >&2
    exit 1
  fi
  [[ ! -e "$IPWHO_TEST_CLOUD_CALLS" && ! -e "$IPWHO_TEST_PROJECTS_SOURCED" ]]
}

run_cli() {
  local expected="$1"
  shift
  run "$expected" "$BASH" "$ROOT_DIR/ipwho" "$@"
}

run_cli 2 203.0.113.10
[[ ! -s "$lookup_test_dir/stdout" && -s "$lookup_test_dir/stderr" ]]
[[ ! -e "$XDG_CACHE_HOME" ]]
grep -q 'ipwho sync' "$lookup_test_dir/stderr"
printf 'PASS: missing cache fails clearly, without cloud calls or creating files\n'

mkdir -p "$XDG_CACHE_HOME/ipwho"
fixture='{
  "version": 1,
  "generated_at": "2020-01-02T03:04:05Z",
  "scope": {"gcp": {"projects": ["project-a", "project-b"]}},
  "resources": {
    "203.0.113.10": [
      {"type":"cloud_nat","provider":"gcp","project":"project-a","location":"europe-west1","direction":"egress","resource":{"name":"nat-a","router":"router-a"},"mode":"AUTO_ONLY","usage":"IN_USE"},
      {"type":"forwarding_rule","provider":"gcp","project":"project-a","location":"global","direction":"ingress","resource":{"name":"http-a"},"scheme":"EXTERNAL_MANAGED","protocol":"TCP","ports":["80","8080"],"hosts":["api.example.com","*.example.com"]},
      {"type":"forwarding_rule","provider":"gcp","project":"project-b","location":"europe-west1","resource":{"name":"https-b"},"protocol":"TCP","port_range":"443-443","hosts":[]},
      {"type":"forwarding_rule","provider":"gcp","project":"project-b","location":"global","resource":{"name":"all-ports-b"},"protocol":"TCP","all_ports":true},
      {"type":"compute_instance","provider":"gcp","project":"project-b","location":"europe-west1-b","resource":{"name":"vm-b","id":"1234567890123456789","interface":"nic0"},"status":"RUNNING","prefix_length":32}
    ],
    "198.51.100.20": [{"type":"compute_instance","resource":{"name":"unrelated"}}],
    "192.0.2.20": []
  }
}'
printf '%s\n' "$fixture" >"$IPWHO_TEST_CACHE"
cp "$IPWHO_TEST_CACHE" "$lookup_test_dir/previous-cache"

run_cli 0 203.0.113.10
[[ -s "$lookup_test_dir/stdout" && ! -s "$lookup_test_dir/stderr" ]]
for expected_line in \
  'IPv4: 203.0.113.10' \
  'Cache generated at: 2020-01-02T03:04:05Z' \
  'GCP projects: project-a, project-b' \
  'Provider: gcp' 'Type: cloud_nat' 'Project: project-b' \
  'Name: nat-a' 'Router: router-a' 'Direction: egress' \
  'Mode: AUTO_ONLY' 'Usage: IN_USE' 'Location: global' \
  'Name: http-a' 'Scheme: EXTERNAL_MANAGED' 'Protocol: TCP' \
  'Ports: 80, 8080' 'Ports: 443-443' 'Ports: all' \
  'Hosts: api.example.com, *.example.com' 'Hosts: (none configured)' \
  'Name: vm-b' 'ID: 1234567890123456789' 'Interface: nic0' \
  'Status: RUNNING' 'Location: europe-west1-b'; do
  grep -Fq -- "$expected_line" "$lookup_test_dir/stdout"
done
[[ $(grep -c '^Resource ' "$lookup_test_dir/stdout") -eq 5 ]]
if grep -q 'unrelated' "$lookup_test_dir/stdout"; then exit 1; fi
cmp -s "$IPWHO_TEST_CACHE" "$lookup_test_dir/previous-cache"
printf 'PASS: all matching resources, metadata and type-specific details are readable; cache unchanged\n'

for ip in 203.0.113.1 192.0.2.20 0.0.0.0 255.255.255.255 1.2.3.4; do
  run_cli 1 "$ip"
  [[ ! -s "$lookup_test_dir/stdout" && -s "$lookup_test_dir/stderr" ]]
  grep -q 'absent from the cache' "$lookup_test_dir/stderr"
done
printf 'PASS: absent addresses and empty resource arrays return 1, without partial matches\n'

for ip in 256.0.0.1 1.2.3.999 1.2.3.4.5 127.1 01.2.3.4 1.02.3.4 \
  1.2.3.004 1.2.3.-1 1.2.3.+1 1.2.3.4/32 example.com \
  ' 1.2.3.4' '1.2.3.4 ' $'1.2.3.4\n' '2001:db8::1' '::ffff:192.0.2.1'; do
  run_cli 2 "$ip"
  [[ ! -s "$lookup_test_dir/stdout" ]]
  grep -q 'only IPv4 addresses' "$lookup_test_dir/stderr"
done
run_cli 2 --json 203.0.113.10
printf 'PASS: malformed, ambiguous and IPv6 inputs are rejected; no JSON option\n'

for invalid in empty malformed array multiple version timestamp scope resources; do
  case "$invalid" in
  empty) : >"$IPWHO_TEST_CACHE" ;;
  malformed) printf '{broken\n' >"$IPWHO_TEST_CACHE" ;;
  array) printf '[]\n' >"$IPWHO_TEST_CACHE" ;;
  multiple) printf '%s\n%s\n' "$fixture" "$fixture" >"$IPWHO_TEST_CACHE" ;;
  version) jq '.version = 2' <<<"$fixture" >"$IPWHO_TEST_CACHE" ;;
  timestamp) jq '.generated_at = null' <<<"$fixture" >"$IPWHO_TEST_CACHE" ;;
  scope) jq '.scope.gcp.projects = []' <<<"$fixture" >"$IPWHO_TEST_CACHE" ;;
  resources) jq '.resources["203.0.113.10"] = ["not an object"]' <<<"$fixture" >"$IPWHO_TEST_CACHE" ;;
  esac
  run_cli 2 203.0.113.10
  [[ ! -s "$lookup_test_dir/stdout" ]]
  grep -q 'ipwho sync' "$lookup_test_dir/stderr"
done
jq '.resources["203.0.113.10"][1].hosts = 42' <<<"$fixture" >"$IPWHO_TEST_CACHE"
run_cli 2 203.0.113.10
[[ ! -s "$lookup_test_dir/stdout" ]]
printf 'PASS: invalid caches and malformed display data return 2 without partial output\n'

printf '%s\n' "$fixture" >"$IPWHO_TEST_CACHE"
jq '.resources = {} | .generated_at = "2026-01-01T00:00:00Z"' <<<"$fixture" >"$IPWHO_TEST_REPLACEMENT"
# Replace the on-disk snapshot after loading it, before lookup renders its data.
jq() {
  command jq "$@" || return $?
  if [[ "${IPWHO_TEST_REPLACE_CACHE:-0}" -eq 1 && "$1" == -cse ]]; then
    cp "$IPWHO_TEST_REPLACEMENT" "$IPWHO_TEST_CACHE.next"
    mv "$IPWHO_TEST_CACHE.next" "$IPWHO_TEST_CACHE"
  fi
}
export -f jq
export IPWHO_TEST_REPLACE_CACHE=1
run_cli 0 203.0.113.10
unset IPWHO_TEST_REPLACE_CACHE
grep -q 'Cache generated at: 2020-01-02T03:04:05Z' "$lookup_test_dir/stdout"
command jq -e '.resources == {}' "$IPWHO_TEST_CACHE" >/dev/null
printf 'PASS: lookup renders one validated snapshot even when the file is replaced\n'

printf '%s\n' "$fixture" >"$IPWHO_TEST_CACHE"
mkdir -p "$lookup_test_dir/bin"
ln -s "$(type -P jq)" "$lookup_test_dir/bin/jq"
ln -s "$(type -P dirname)" "$lookup_test_dir/bin/dirname"
run 0 env PATH="$lookup_test_dir/bin" "$BASH" "$ROOT_DIR/ipwho" 203.0.113.10
printf 'PASS: lookup works without gcloud on PATH\n'

mkdir -p "$HOME/.cache/ipwho"
printf '%s\n' "$fixture" >"$HOME/.cache/ipwho/cache.json"
run 0 env -u XDG_CACHE_HOME "$BASH" "$ROOT_DIR/ipwho" 203.0.113.10
printf 'PASS: lookup shares the sync cache path and HOME fallback\n'
