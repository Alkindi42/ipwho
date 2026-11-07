#!/usr/bin/env bash

OVH_PROVIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OVH_PROVIDER_DIR

fetch_ovh_servers() {
  local servers

  servers="$("${IPWHO_OVH_PYTHON:-python3}" "$OVH_PROVIDER_DIR/ovh_api.py")" || return 1

  jq -cs '
    def hostname:
      rtrimstr(".") |
      length <= 253 and test("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$") and
      (test("^[0-9.]+$") | not) and
      (split(".") | all(.[]; length <= 63 and test("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$")));
    (if length == 1 and (.[0] | type) == "array" then .[0]
     else error("Invalid OVH server list") end) |
    .[] |
    (.displayName // "") as $hostname |
    {
      (.ip): [{
        type: "dedicated_server",
        provider: "ovh",
        location: ([.availabilityZone, .region, .datacenter] |
          map(select(. != null and . != "")) | .[0]),
        region: .region,
        zone: .availabilityZone,
        datacenter: .datacenter,
        commercial_name: .commercialName,
        resource: {
          name: (if $hostname != "" then $hostname else .name end),
          id: .serverId,
          service_name: .name
        },
        hosts: (if ($hostname | hostname) then [$hostname] else [] end)
      }]
    }
  ' <<<"$servers" || return 1
}
