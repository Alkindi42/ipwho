#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

# shellcheck source=lib/sync.sh
source "$ROOT_DIR/lib/sync.sh"

cache_test_dir="$(mktemp -d)"
trap 'rm -rf "$cache_test_dir"' EXIT
export XDG_CACHE_HOME="$cache_test_dir/cache with spaces"
test_cache_dir="$XDG_CACHE_HOME/ipwho"
test_cache_file="$test_cache_dir/cache.json"
cache_scenario='success'
GCP_PROJECTS=(first-project second-project)

# All cloud requests are mocked, including failures followed by successful data.
gcloud() {
  local argument request_project=''
  for argument in "$@"; do
    case "$argument" in
    --project=*) request_project="${argument#--project=}" ;;
    esac
  done
  printf '%s\n' "$*" >>"$cache_test_dir/calls"

  if [[ "${check_previous_cache:-0}" -eq 1 ]]; then
    cmp -s "$test_cache_file" "$cache_test_dir/previous-cache" || return 1
  fi

  case "$1 $2 $3" in
  'compute routers list')
    if [[ "$cache_scenario" == empty ]]; then printf '[]\n'; return 0; fi
    if [[ "$request_project" == first-project && "$cache_scenario" == routers-failure ]]; then
      printf 'Mock router listing failure\n' >&2
      return 1
    fi
    if [[ "$cache_scenario" == nat-failure ]]; then
      printf '[{"name":"router-one","region":"regions/europe-west1","nats":[{"name":"nat"}]},{"name":"router-two","region":"regions/europe-west1","nats":[{"name":"nat"}]}]\n'
    else
      printf '[{"name":"router-without-nat","region":"regions/europe-west1"},{"name":"router-one","region":"regions/europe-west1","nats":[{"name":"nat"}]}]\n'
    fi
    ;;
  'compute routers get-nat-ip-info')
    if [[ "$4" == router-without-nat ]]; then
      printf 'Nat name not found.\n' >&2
      return 1
    fi
    if [[ "$request_project" == first-project ]]; then
      case "$cache_scenario" in
      nat-failure)
        if [[ "$4" == router-one ]]; then
          printf 'Mock NAT failure\n' >&2
          return 1
        fi
        ;;
      nat-json) printf '{broken\n'; return 0 ;;
      esac
    fi
    printf '{"result":[{"natName":"nat","natIpInfoMappings":[{"natIp":"203.0.113.10","mode":"AUTO_ONLY","usage":"IN_USE"}]}]}\n'
    ;;
  'compute forwarding-rules list')
    if [[ "$cache_scenario" == empty ]]; then printf '[]\n'; return 0; fi
    if [[ "$request_project" == first-project ]]; then
      case "$cache_scenario" in
      rules-failure) printf 'Mock rule listing failure\n' >&2; return 1 ;;
      rules-json) printf '{broken\n'; return 0 ;;
      proxy-failure | map-failure | map-json)
        printf '[{"name":"https","IPAddress":"203.0.113.11","loadBalancingScheme":"EXTERNAL_MANAGED","target":"https://www.googleapis.com/compute/v1/projects/first-project/global/targetHttpsProxies/proxy"},{"name":"tcp","IPAddress":"203.0.113.10","loadBalancingScheme":"EXTERNAL","IPProtocol":"TCP"}]\n'
        return 0
        ;;
      esac
    fi
    printf '[{"name":"public-lb","IPAddress":"203.0.113.10","loadBalancingScheme":"EXTERNAL","IPProtocol":"TCP"}]\n'
    ;;
  'compute target-https-proxies describe')
    if [[ "$cache_scenario" == proxy-failure ]]; then
      printf 'Mock proxy failure\n' >&2
      return 1
    fi
    printf 'https://www.googleapis.com/compute/v1/projects/first-project/global/urlMaps/map\n'
    ;;
  'compute url-maps describe')
    if [[ "$cache_scenario" == map-failure ]]; then
      printf 'Mock URL map failure\n' >&2
      return 1
    fi
    printf '{broken\n'
    ;;
  'compute instances list')
    if [[ "$cache_scenario" == empty ]]; then printf '[]\n'; return 0; fi
    if [[ "$request_project" == first-project ]]; then
      case "$cache_scenario" in
      compute-failure) printf 'Mock Compute API failure\n' >&2; return 1 ;;
      compute-json) printf '{broken\n'; return 0 ;;
      esac
    fi
    printf '[{"name":"vm","id":"1","zone":"europe-west1-b","status":"RUNNING","networkInterfaces":[{"name":"nic0","accessConfigs":[{"natIP":"203.0.113.10"}]}]}]\n'
    ;;
  *) printf 'Unexpected gcloud call: %s\n' "$*" >&2; return 1 ;;
  esac
}

assert_no_temporary_files() {
  [[ -z "$(find "$test_cache_dir" -maxdepth 1 -name '.cache.*' -print)" ]]
}

expect_preserved_cache() {
  local status=0
  : >"$cache_test_dir/calls"
  # The conditional intentionally disables errexit: errors must propagate explicitly.
  sync >"$cache_test_dir/stdout" 2>"$cache_test_dir/stderr" || status=$?
  [[ "$status" -eq 1 && ! -s "$cache_test_dir/stdout" && -s "$cache_test_dir/stderr" ]]
  if grep -q 'Sync completed' "$cache_test_dir/stderr"; then
    printf 'FAIL: failed sync reported success\n' >&2
    exit 1
  fi
  cmp -s "$test_cache_file" "$cache_test_dir/previous-cache"
  assert_no_temporary_files
}

original_umask="$(umask)"
(
  umask 000
  permissive_umask="$(umask)"
  trap ':' INT TERM
  original_traps="$(trap -p EXIT INT TERM)"
  sync
  [[ "$(umask)" == "$permissive_umask" && "$(trap -p EXIT INT TERM)" == "$original_traps" ]]
) >"$cache_test_dir/stdout" 2>"$cache_test_dir/stderr"
[[ ! -s "$cache_test_dir/stdout" && -s "$cache_test_dir/stderr" ]]
[[ $(wc -l <"$cache_test_dir/stderr") -eq 4 ]]
grep -Fxq '[ipwho] Sync started' "$cache_test_dir/stderr"
grep -Fxq '[ipwho] GCP [1/2]: first-project' "$cache_test_dir/stderr"
grep -Fxq '[ipwho] GCP [2/2]: second-project' "$cache_test_dir/stderr"
grep -Eq '^\[ipwho\] Sync completed in [0-9]+s; cache: ' "$cache_test_dir/stderr"
[[ "$(umask)" == "$original_umask" ]]
[[ "$(ls -ld "$test_cache_dir")" == drwx------* ]]
[[ "$(ls -l "$test_cache_file")" == -rw-------* ]]
jq empty "$test_cache_file"
jq -e '
  .version == 1 and
  (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  .scope.gcp.projects == ["first-project", "second-project"] and
  (.resources | length == 1) and
  (.resources["203.0.113.10"] | length == 6)
' "$test_cache_file" >/dev/null
assert_no_temporary_files
cp "$test_cache_file" "$cache_test_dir/previous-cache"
printf 'PASS: private cache, metadata and aggregation; stdout and caller umask unchanged\n'

for cache_scenario in routers-failure nat-failure nat-json rules-failure rules-json proxy-failure map-failure map-json compute-failure compute-json; do
  expect_preserved_cache
  if grep -q -- '--project=second-project' "$cache_test_dir/calls"; then
    printf 'FAIL: collection continued after a failed project\n' >&2
    exit 1
  fi
  printf 'PASS: %s preserves the previous cache and stops before the next project\n' "$cache_scenario"
done
cache_scenario='success'

for invalid_schema in empty malformed version timestamp scope resources multiple; do
  (
    generate_inventory() {
      case "$invalid_schema" in
      empty) return 0 ;;
      malformed) printf '{broken\n' ;;
      version) jq '.version = 2' "$cache_test_dir/previous-cache" ;;
      timestamp) jq '.generated_at = null' "$cache_test_dir/previous-cache" ;;
      scope) jq '.scope.gcp.projects = []' "$cache_test_dir/previous-cache" ;;
      resources) jq '.resources = {"203.0.113.10": ["not an object"]}' "$cache_test_dir/previous-cache" ;;
      multiple) printf '%s\n%s\n' "$(<"$cache_test_dir/previous-cache")" "$(<"$cache_test_dir/previous-cache")" ;;
      esac
    }
    expect_preserved_cache
  )
  printf 'PASS: invalid inventory (%s) is rejected without replacing the cache\n' "$invalid_schema"
done

(
  generate_inventory() { printf '{"partial":true}\n'; return 1; }
  expect_preserved_cache
)
printf 'PASS: valid partial JSON with a failed collection never replaces the cache\n'

(
  mkdir() { printf 'Mock directory creation failure\n' >&2; return 1; }
  expect_preserved_cache
)
(
  mktemp() { printf 'Mock temporary file creation failure\n' >&2; return 1; }
  expect_preserved_cache
)
(
  mv() { printf 'Mock rename failure\n' >&2; return 1; }
  expect_preserved_cache
)
printf 'PASS: directory, temporary file and rename failures preserve the cache\n'

for signal in INT TERM; do
  (
    # Job control prevents background jobs from inheriting an ignored SIGINT.
    set -m
    rm -f "$cache_test_dir/ready"
    generate_inventory() {
      : >"$cache_test_dir/ready"
      sleep 1
      printf '%s\n' "$(<"$cache_test_dir/previous-cache")"
    }
    sync >"$cache_test_dir/stdout" 2>"$cache_test_dir/stderr" &
    sync_pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
      [[ -e "$cache_test_dir/ready" ]] && break
      sleep 0.01
    done
    [[ -e "$cache_test_dir/ready" ]]
    kill -s "$signal" "$sync_pid"
    status=0
    wait "$sync_pid" || status=$?
    if [[ "$signal" == INT ]]; then
      [[ "$status" -eq 130 ]]
    else
      [[ "$status" -eq 143 ]]
    fi
    cmp -s "$test_cache_file" "$cache_test_dir/previous-cache"
    assert_no_temporary_files
  )
  printf 'PASS: SIG%s cleans up the temporary file and preserves the cache\n' "$signal"
done

cache_scenario='empty'
GCP_PROJECTS=(second-project)
check_previous_cache=1
sync >"$cache_test_dir/stdout" 2>"$cache_test_dir/stderr"
unset check_previous_cache
jq -e '.scope.gcp.projects == ["second-project"] and .resources == {}' "$test_cache_file" >/dev/null
assert_no_temporary_files
printf 'PASS: readers retain the old snapshot during collection; empty success replaces it completely\n'

(
  unset XDG_CACHE_HOME
  export HOME="$cache_test_dir/home"
  sync >"$cache_test_dir/stdout" 2>"$cache_test_dir/stderr"
  jq -e '.resources == {}' "$HOME/.cache/ipwho/cache.json" >/dev/null
)
printf 'PASS: cache path falls back to HOME/.cache when XDG_CACHE_HOME is unset\n'

(
  export XDG_CACHE_HOME="$cache_test_dir/directory-target"
  mkdir -p "$XDG_CACHE_HOME/ipwho/cache.json"
  status=0
  sync >"$cache_test_dir/stdout" 2>"$cache_test_dir/stderr" || status=$?
  [[ "$status" -eq 1 && -d "$XDG_CACHE_HOME/ipwho/cache.json" ]]
  [[ -z "$(find "$XDG_CACHE_HOME/ipwho" -name '.cache.*' -print)" ]]
)
printf 'PASS: a directory at the cache file path is rejected, not used as a destination\n'
