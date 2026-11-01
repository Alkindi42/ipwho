#!/usr/bin/env bash

fetch_gcp_nat_ips() {
  local ret=0
  local project="$1"
  local ips mappings ip nat_name mode usage
  local routers router_name router_region

  routers="$(
    gcloud compute routers list \
      --project="$project" \
      --format="value(name,region)"
  )"

  if [[ -n "$routers" ]]; then
    while IFS=$'\t' read -r router_name router_region; do
      [[ -z "$router_name" || -z "$router_region" ]] && continue

      ips="$(gcloud compute routers get-nat-ip-info "$router_name" \
        --region="$router_region" \
        --project="$project" \
        --format=json)" || {
        ret=1
        continue
      }

      mappings="$(jq -r '
        .result[] as $nat |
        $nat.natIpInfoMappings[]? |
        [.natIp, $nat.natName, .mode, .usage] | @tsv
      ' <<<"$ips")" || {
        ret=1
        continue
      }

      while IFS=$'\t' read -r ip nat_name mode usage; do
        [[ -z "$ip" ]] && continue

        jq -cn \
          --arg ip "$ip" \
          --arg project "$project" \
          --arg region "$router_region" \
          --arg nat "$nat_name" \
          --arg router "$router_name" \
          --arg mode "$mode" \
          --arg usage "$usage" \
          '{
            ($ip): [{
              type: "cloud_nat",
              project: $project,
              direction: "egress",
              provider: "gcp",
              location: $region,
              resource: {
                name: $nat,
                router: $router
              },
              mode: $mode,
              usage: $usage
            }]
          }'

      done <<<"$mappings"
    done <<<"$routers"
  fi

  return "$ret"
}

sync_gcp() {
  for project in "${GCP_PROJECTS[@]}"; do
    fetch_gcp_nat_ips "$project"
  done
}
