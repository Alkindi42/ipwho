#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

# shellcheck source=lib/sync.sh
source "$ROOT_DIR/lib/sync.sh"

scenario='success'
compute_instances_json='[
  {
    "name": "public-vm",
    "id": "1234567890123456789",
    "zone": "https://www.googleapis.com/compute/v1/projects/test-project/zones/europe-west1-b",
    "status": "RUNNING",
    "networkInterfaces": [
      {
        "name": "nic0",
        "networkIP": "10.0.0.2",
        "ipv6Address": "fd20::2",
        "accessConfigs": [{"natIP": "203.0.113.10"}, {}, {"natIP": ""}],
        "ipv6AccessConfigs": [{"externalIpv6": "2001:db8:1::", "externalIpv6PrefixLength": 96}]
      },
      {
        "name": "nic1",
        "networkIP": "10.1.0.2",
        "accessConfigs": [{"natIP": "198.51.100.20"}]
      }
    ]
  },
  {
    "name": "private-vm",
    "networkInterfaces": [{"name": "nic0", "networkIP": "10.0.0.3", "ipv6Address": "fd20::3"}]
  },
  {
    "name": "stopped-vm",
    "id": "2",
    "zone": "us-central1-a",
    "status": "TERMINATED",
    "networkInterfaces": [{"name": "nic0", "accessConfigs": [{"natIP": "203.0.113.10"}]}]
  },
  {
    "name": "ipv6-only-vm",
    "id": "3",
    "zone": "europe-west1-c",
    "status": "RUNNING",
    "networkInterfaces": [{
      "name": "nic0",
      "ipv6AccessConfigs": [{"externalIpv6": "2001:db8:2::1", "externalIpv6PrefixLength": 128}]
    }]
  },
  {"name": "no-interfaces-vm"},
  {"name": "empty-configs-vm", "networkInterfaces": [{"name": "nic0", "accessConfigs": [], "ipv6AccessConfigs": []}]}
]'

# All gcloud calls are mocked; these tests never access cloud resources.
gcloud() {
  case "$*" in
  "compute instances list --project=test-project --format=json" | \
    "compute instances list --project=another-project --format=json")
    case "$scenario" in
    success) printf '%s\n' "$compute_instances_json" ;;
    empty) printf '[]\n' ;;
    private) printf '[{"networkInterfaces":[{"networkIP":"10.0.0.2","ipv6Address":"fd20::2"}]}]\n' ;;
    failure) printf 'Mock Compute API failure\n' >&2; return 2 ;;
    malformed) printf '{broken\n' ;;
    invalid) printf '[{"networkInterfaces":[{"accessConfigs":[{"natIP":42}]}]}]\n' ;;
    *) printf 'Unexpected scenario: %s\n' "$scenario" >&2; return 1 ;;
    esac
    ;;
  "compute routers list --project=test-project --format=json" | \
    "compute routers list --project=another-project --format=json")
    printf '[{"name":"router","region":"regions/europe-west1","nats":[{"name":"nat"}]}]\n'
    ;;
  "compute routers get-nat-ip-info router --region=europe-west1 --project=test-project --format=json" | \
    "compute routers get-nat-ip-info router --region=europe-west1 --project=another-project --format=json")
    printf '{"result":[{"natName":"nat","natIpInfoMappings":[{"natIp":"203.0.113.10","mode":"AUTO_ONLY","usage":"IN_USE"}]}]}\n'
    ;;
  "compute forwarding-rules list --project=test-project --format=json" | \
    "compute forwarding-rules list --project=another-project --format=json")
    printf '[{"name":"public-lb","IPAddress":"203.0.113.10","loadBalancingScheme":"EXTERNAL","IPProtocol":"TCP","allPorts":true}]\n'
    ;;
  *) printf 'Unexpected gcloud call: %s\n' "$*" >&2; return 1 ;;
  esac
}

output="$(fetch_gcp_compute_ips test-project)"
jq empty <<<"$output"
jq -se '
  length == 5 and
  ([.[] | .[][] | .type] | all(. == "compute_instance")) and
  ([.[] | .[][] | .project] | all(. == "test-project")) and
  ([.[] | .[][] | .provider] | all(. == "gcp")) and
  (.[0]["203.0.113.10"][0] |
    .location == "europe-west1-b" and
    .resource.name == "public-vm" and
    .resource.id == "1234567890123456789" and
    .resource.interface == "nic0" and
    .status == "RUNNING" and
    .prefix_length == 32) and
  (.[1]["2001:db8:1::"][0].prefix_length == 96) and
  (.[2]["198.51.100.20"][0].resource.interface == "nic1") and
  (.[3]["203.0.113.10"][0] |
    .location == "us-central1-a" and .status == "TERMINATED") and
  (.[4]["2001:db8:2::1"][0].prefix_length == 128)
' <<<"$output" >/dev/null
printf 'PASS: public IPv4/IPv6, multiple interfaces, zones, IDs and stopped VMs\n'

for scenario in empty private; do
  output="$(fetch_gcp_compute_ips test-project)"
  [[ -z "$output" ]]
  printf 'PASS: %s collection succeeds without resources\n' "$scenario"
done

for scenario in failure malformed invalid; do
  status=0
  output="$(fetch_gcp_compute_ips test-project 2>&1)" || status=$?
  [[ "$status" -eq 1 && -n "$output" ]]
  printf 'PASS: %s collection returns 1 and reports an error\n' "$scenario"
done

scenario='success'
GCP_PROJECTS=(test-project another-project)
output="$(generate_inventory)"
jq empty <<<"$output"
jq -e '
  (.generated_at | type == "string") and
  (.resources | length == 4) and
  (.resources["203.0.113.10"] | length == 8) and
  ([.resources["203.0.113.10"][].type] | unique == ["cloud_nat", "compute_instance", "forwarding_rule"]) and
  ([.resources["203.0.113.10"][].project] | unique == ["another-project", "test-project"])
' <<<"$output" >/dev/null
printf 'PASS: inventory aggregates Cloud NAT, forwarding rules and VMs across projects\n'

scenario='failure'
GCP_PROJECTS=(test-project)
status=0
output="$(generate_inventory 2>/dev/null)" || status=$?
[[ "$status" -eq 1 ]]
printf 'PASS: inventory generation propagates Compute API failures\n'
