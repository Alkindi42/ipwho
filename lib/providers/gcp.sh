#!/usr/bin/env bash

fetch_forwarding_rules() {
  local ret=0
  local project="$1"
  local hosts_cache='{}'
  local forwarding_rules rules rule target proxy_type url_map map hosts

  forwarding_rules="$(
    gcloud compute forwarding-rules list \
      --project="$project" \
      --format=json
  )" || return 1

  rules="$(jq -c '
    .[] |
    select(.loadBalancingScheme == "EXTERNAL" or .loadBalancingScheme == "EXTERNAL_MANAGED") |
    select(.IPAddress != null and .IPAddress != "")
  ' <<<"$forwarding_rules")" || return 1

  if [[ -n "$rules" ]]; then
    while IFS= read -r rule; do
      target="$(jq -r '.target // empty' <<<"$rule")" || {
        ret=1
        continue
      }
      hosts='[]'
      proxy_type=''

      case "$target" in
      */targetHttpProxies/*) proxy_type='target-http-proxies' ;;
      */targetHttpsProxies/*) proxy_type='target-https-proxies' ;;
      esac

      if [[ -n "$proxy_type" ]]; then
        hosts="$(jq -c --arg key "$target" '.[$key] // empty' <<<"$hosts_cache")" || {
          ret=1
          continue
        }

        if [[ -z "$hosts" ]]; then
          # Full resource URLs let gcloud resolve the project and global/regional scope.
          url_map="$(gcloud compute "$proxy_type" describe "$target" \
            --project="$project" \
            --format="value(urlMap)")" || {
            ret=1
            continue
          }

          if [[ -z "$url_map" ]]; then
            printf 'No URL map found for proxy %s\n' "$target" >&2
            ret=1
            continue
          fi

          hosts="$(jq -c --arg key "$url_map" '.[$key] // empty' <<<"$hosts_cache")" || {
            ret=1
            continue
          }

          if [[ -z "$hosts" ]]; then
            map="$(gcloud compute url-maps describe "$url_map" \
              --project="$project" \
              --format=json)" || {
              ret=1
              continue
            }

            hosts="$(jq -c '[.hostRules[]? | .hosts[]] | unique' <<<"$map")" || {
              ret=1
              continue
            }
          fi

          # Reuse hosts when multiple frontends share a proxy or URL map.
          hosts_cache="$(jq -c \
            --arg target "$target" \
            --arg url_map "$url_map" \
            --argjson hosts "$hosts" \
            '.[$target] = $hosts | .[$url_map] = $hosts' <<<"$hosts_cache")" || {
            ret=1
            continue
          }
        fi
      fi

      jq -c \
        --arg project "$project" \
        --argjson hosts "$hosts" \
        '{
          (.IPAddress): [{
            type: "forwarding_rule",
            project: $project,
            direction: "ingress",
            provider: "gcp",
            location: ((.region // "global") | split("/")[-1]),
            resource: {name: .name},
            scheme: .loadBalancingScheme,
            protocol: .IPProtocol,
            ports: (.ports // []),
            port_range: (.portRange // null),
            all_ports: (.allPorts // false),
            hosts: $hosts
          }]
        }' <<<"$rule" || ret=1
    done <<<"$rules"
  fi

  return "$ret"
}

fetch_gcp_nat_ips() {
  local ret=0
  local project="$1"
  local ips mappings ip nat_name mode usage
  local routers router_name router_region

  routers="$(
    gcloud compute routers list \
      --project="$project" \
      --format=json
  )" || return 1

  routers="$(jq -r '
    .[] |
    select((.nats // []) | length > 0) |
    [.name, (.region | split("/")[-1])] | @tsv
  ' <<<"$routers")" || return 1

  if [[ -n "$routers" ]]; then
    while IFS=$'\t' read -r router_name router_region; do
      [[ -z "$router_name" || -z "$router_region" ]] && continue

      ips="$(gcloud compute routers get-nat-ip-info "$router_name" \
        --region="$router_region" \
        --project="$project" \
        --format=json)" || {
        printf 'Error: could not collect NAT IPs for project %s, router %s (%s).\n' \
          "$project" "$router_name" "$router_region" >&2
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
          }' || ret=1

      done <<<"$mappings"
    done <<<"$routers"
  fi

  return "$ret"
}

fetch_gcp_compute_ips() {
  local project="$1"
  local instances

  instances="$(
    gcloud compute instances list \
      --project="$project" \
      --format=json
  )" || return 1

  jq -c --arg project "$project" '
    .[] as $instance |
    $instance.networkInterfaces[]? as $interface |
    (
      ($interface.accessConfigs[]? | {ip: .natIP, prefix_length: 32}),
      # externalIpv6 is the first address of a range, not necessarily a single IP.
      ($interface.ipv6AccessConfigs[]? | {
        ip: .externalIpv6,
        prefix_length: .externalIpv6PrefixLength
      })
    ) |
    select(.ip != null and .ip != "") |
    . as $address |
    {
      ($address.ip): [{
        type: "compute_instance",
        project: $project,
        provider: "gcp",
        location: ($instance.zone | split("/")[-1]),
        resource: {
          name: $instance.name,
          id: $instance.id,
          interface: $interface.name
        },
        status: $instance.status,
        prefix_length: $address.prefix_length
      }]
    }
  ' <<<"$instances" || return 1
}

sync_gcp() {
  for project in "${GCP_PROJECTS[@]}"; do
    fetch_gcp_nat_ips "$project" || return 1
    fetch_forwarding_rules "$project" || return 1
    fetch_gcp_compute_ips "$project" || return 1
  done
}
