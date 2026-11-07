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

is_host() {
  local host="${1%.}" label
  local -a labels

  [[ ${#host} -le 253 && "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  # Do not interpret malformed IPv4 addresses as hostnames.
  [[ ! "$host" =~ ^[0-9.]+$ ]] || return 1
  IFS=. read -r -a labels <<<"$host"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  return 0
}

lookup() {
  local query="$1" kind
  local cache_file cache matches output

  if is_ipv4 "$query"; then
    kind='IPv4'
  elif is_host "$query"; then
    kind='Host'
  else
    printf 'Error: lookup expects a valid IPv4 address without leading zeros, or an ASCII hostname.\n' >&2
    return 2
  fi

  cache_file="$(cache_file_path)" || return 2
  if [[ ! -f "$cache_file" || ! -r "$cache_file" ]]; then
    printf 'Error: cache is missing or unreadable at %s. Run ipwho sync with your selected providers first.\n' "$cache_file" >&2
    return 2
  fi

  # Read and validate one snapshot, even if sync replaces the file during lookup.
  cache="$(load_cache "$cache_file")" || {
    printf 'Error: invalid or incompatible cache at %s. Run ipwho sync to regenerate it.\n' "$cache_file" >&2
    return 2
  }
  matches="$(jq -c --arg query "$query" --arg kind "$kind" '
    . as $cache |
    (if $kind == "IPv4" then
      [.resources[$query][]? | {ip: $query, resource: .}]
    else
      ($query | ascii_downcase | rtrimstr(".")) as $host |
      [.resources | to_entries[] |
        select(.key | contains(":") | not) |
        .key as $ip | .value[] | . as $resource |
        [(.hosts // [])[] | . as $rule |
          (ascii_downcase | rtrimstr(".")) as $pattern |
          select($pattern != "*" and
            ($pattern == $host or
              (($pattern | startswith("*.")) and ($host | endswith($pattern[1:]))))) |
          $rule
        ] | unique as $rules |
        select($rules | length > 0) |
        {ip: $ip, resource: $resource, matched_rules: $rules}]
    end) as $matches |
    select($matches | length > 0) |
    {generated_at: $cache.generated_at, scope: $cache.scope, matches: $matches}
  ' <<<"$cache")" || {
    printf 'Error: invalid resource data in cache at %s. Run ipwho sync to regenerate it.\n' "$cache_file" >&2
    return 2
  }
  if [[ -z "$matches" ]]; then
    printf '%s %s is absent from the cache at %s.\n' "$kind" "$query" "$cache_file" >&2
    return 1
  fi

  output="$(jq -r --arg query "$query" --arg kind "$kind" '
    (if $kind == "IPv4" then "IPv4: \($query)"
     else "Host: \($query | ascii_downcase | rtrimstr("."))" end),
    "Cache generated at: \(.generated_at)",
    (if .scope.gcp != null then "GCP projects: \(.scope.gcp.projects | join(", "))" else empty end),
    (if .scope.ovh != null then "OVH: dedicated servers" else empty end),
    (.matches | to_entries[] |
      "",
      "Resource \(.key + 1):",
      (.value |
        (if $kind == "Host" then
          "  IPv4: \(.ip)",
          "  Matched rules: \(.matched_rules | join(", "))"
         else empty end),
        (.resource | {
        Provider: .provider,
        Type: .type,
        Project: .project,
        Name: .resource.name,
        "Service name": .resource.service_name,
        "Commercial name": .commercial_name,
        Location: .location,
        Region: .region,
        Zone: .zone,
        Datacenter: .datacenter,
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
      "  \(.key): \(.value)")))
  ' <<<"$matches")" || {
    printf 'Error: invalid resource data in cache at %s. Run ipwho sync to regenerate it.\n' "$cache_file" >&2
    return 2
  }
  printf '%s\n' "$output"
}
