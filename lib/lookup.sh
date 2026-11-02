#!/usr/bin/env bash

# shellcheck source=lib/cache.sh
source "$(dirname "${BASH_SOURCE[0]}")/cache.sh"

is_ipv4() {
  local ip="$1" octet
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    if [[ ${#octet} -gt 1 && "$octet" == 0* ]] || ((10#$octet > 255)); then
      return 1
    fi
  done
  return 0
}

lookup_ip() {
  local ip="$1"
  local cache_file cache matches output

  if ! is_ipv4 "$ip"; then
    printf 'Error: lookup accepts only IPv4 addresses in dotted-decimal notation, without leading zeros.\n' >&2
    return 2
  fi

  cache_file="$(cache_file_path)" || return 2
  if [[ ! -f "$cache_file" || ! -r "$cache_file" ]]; then
    printf 'Error: cache is missing or unreadable at %s. Run ipwho sync with your GCP projects first.\n' "$cache_file" >&2
    return 2
  fi

  # Read and validate one snapshot, even if sync replaces the file during lookup.
  cache="$(load_cache "$cache_file")" || {
    printf 'Error: invalid or incompatible cache at %s. Run ipwho sync to regenerate it.\n' "$cache_file" >&2
    return 2
  }
  matches="$(jq -r --arg ip "$ip" '(.resources[$ip] // []) | length' <<<"$cache")" || return 2
  if [[ "$matches" -eq 0 ]]; then
    printf 'IP %s is absent from the cache at %s.\n' "$ip" "$cache_file" >&2
    return 1
  fi

  output="$(jq -r --arg ip "$ip" '
    "IPv4: \($ip)",
    "Cache generated at: \(.generated_at)",
    "GCP projects: \(.scope.gcp.projects | join(", "))",
    (.resources[$ip] | to_entries[] |
      "",
      "Resource \(.key + 1):",
      (.value | {
        Provider: .provider,
        Type: .type,
        Project: .project,
        Name: .resource.name,
        Location: .location,
        Direction: .direction,
        ID: .resource.id,
        Router: .resource.router,
        Interface: .resource.interface,
        Status: .status,
        Mode: .mode,
        Usage: .usage,
        Scheme: .scheme,
        Protocol: .protocol,
        Ports: (if .all_ports == true then "all"
                elif (.ports // [] | length) > 0 then (.ports | join(", "))
                else .port_range end),
        Hosts: (if has("hosts") then
                  if (.hosts | length) == 0 then "(none configured)"
                  else (.hosts | join(", ")) end
                else null end),
        "Prefix length": .prefix_length
      } | to_entries[] | select(.value != null and .value != "") |
      "  \(.key): \(.value)"))
  ' <<<"$cache")" || {
    printf 'Error: invalid resource data in cache at %s. Run ipwho sync to regenerate it.\n' "$cache_file" >&2
    return 2
  }
  printf '%s\n' "$output"
}
