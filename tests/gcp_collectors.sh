#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

# shellcheck source=lib/providers/gcp.sh
source "$ROOT_DIR/lib/providers/gcp.sh"

collectors_test_dir="$(mktemp -d)"
trap 'rm -rf "$collectors_test_dir"' EXIT
routers_fixture='[]'
rules_fixture='[]'
collector_scenario='success'

# Strict mocks reject CLI filters, which warn on projects with no resources.
gcloud() {
  printf '%s\n' "$*" >>"$collectors_test_dir/calls"
  case "$*" in
  'compute routers list --project=test-project --format=json')
    if [[ "$collector_scenario" == list-failure ]]; then
      printf 'Mock router listing failure\n' >&2
      return 1
    fi
    printf '%s\n' "$routers_fixture"
    ;;
  'compute routers get-nat-ip-info router-nat --region=europe-west1 --project=test-project --format=json')
    if [[ "$collector_scenario" == nat-failure ]]; then
      printf 'Nat name not found.\n' >&2
      return 1
    fi
    printf '{"result":[{"natName":"nat","natIpInfoMappings":[{"natIp":"203.0.113.10","mode":"AUTO_ONLY","usage":"IN_USE"}]}]}\n'
    ;;
  'compute forwarding-rules list --project=test-project --format=json')
    printf '%s\n' "$rules_fixture"
    ;;
  *) printf 'Unexpected gcloud call: %s\n' "$*" >&2; return 1 ;;
  esac
}

collect() {
  local expected="$1"
  local collector="$2"
  local status=0
  : >"$collectors_test_dir/calls"
  "$collector" test-project >"$collectors_test_dir/stdout" 2>"$collectors_test_dir/stderr" || status=$?
  [[ "$status" -eq "$expected" ]]
}

for collector in fetch_gcp_nat_ips fetch_forwarding_rules; do
  collect 0 "$collector"
  [[ ! -s "$collectors_test_dir/stdout" && ! -s "$collectors_test_dir/stderr" ]]
  [[ $(wc -l <"$collectors_test_dir/calls") -eq 1 ]]
done
printf 'PASS: empty projects succeed without resources or CLI filter warnings\n'

routers_fixture='[
  {"name":"router-no-nats-field","region":"regions/europe-west1"},
  {"name":"router-null-nats","region":"regions/europe-west1","nats":null},
  {"name":"router-empty-nats","region":"regions/europe-west1","nats":[]}
]'
collect 0 fetch_gcp_nat_ips
[[ ! -s "$collectors_test_dir/stdout" && ! -s "$collectors_test_dir/stderr" ]]
[[ $(wc -l <"$collectors_test_dir/calls") -eq 1 ]]
printf 'PASS: routers without NAT configurations are skipped without get-nat-ip-info calls\n'

routers_fixture='[
  {"name":"router-no-nats","region":"regions/europe-west1"},
  {"name":"router-nat","region":"https://www.googleapis.com/compute/v1/projects/test-project/regions/europe-west1","nats":[{"name":"nat"}]}
]'
collect 0 fetch_gcp_nat_ips
[[ ! -s "$collectors_test_dir/stderr" && $(wc -l <"$collectors_test_dir/calls") -eq 2 ]]
jq -se '
  length == 1 and
  (.[0]["203.0.113.10"][0] |
    .location == "europe-west1" and .resource.router == "router-nat" and .resource.name == "nat")
' "$collectors_test_dir/stdout" >/dev/null
printf 'PASS: mixed routers collect only NAT-enabled routers and normalize their region\n'

collector_scenario='nat-failure'
collect 1 fetch_gcp_nat_ips
grep -q 'project test-project, router router-nat (europe-west1)' "$collectors_test_dir/stderr"
printf 'PASS: an API error on a configured NAT remains fatal, with project and router context\n'

collector_scenario='list-failure'
collect 1 fetch_gcp_nat_ips
[[ $(wc -l <"$collectors_test_dir/calls") -eq 1 ]]
collector_scenario='success'
routers_fixture='{broken'
collect 1 fetch_gcp_nat_ips
[[ $(wc -l <"$collectors_test_dir/calls") -eq 1 ]]
printf 'PASS: router listing and JSON parsing errors still propagate\n'

rules_fixture='[
  {"name":"external","IPAddress":"203.0.113.10","loadBalancingScheme":"EXTERNAL","IPProtocol":"TCP"},
  {"name":"managed","IPAddress":"203.0.113.11","loadBalancingScheme":"EXTERNAL_MANAGED","IPProtocol":"TCP"},
  {"name":"internal","IPAddress":"10.0.0.1","loadBalancingScheme":"INTERNAL"},
  {"name":"internal-managed","IPAddress":"10.0.0.2","loadBalancingScheme":"INTERNAL_MANAGED"},
  {"name":"no-scheme","IPAddress":"203.0.113.12"},
  {"name":"no-ip","loadBalancingScheme":"EXTERNAL"}
]'
collect 0 fetch_forwarding_rules
[[ ! -s "$collectors_test_dir/stderr" ]]
jq -se '
  length == 2 and
  (.[0]["203.0.113.10"][0].scheme == "EXTERNAL") and
  (.[1]["203.0.113.11"][0].scheme == "EXTERNAL_MANAGED")
' "$collectors_test_dir/stdout" >/dev/null
printf 'PASS: forwarding rules remain external-only after removing the redundant CLI filter\n'
