# ipwho

**Find the cloud resource behind a public IP or configured hostname.**

`ipwho` is a lightweight Bash CLI for building a local cloud inventory and
searching it during troubleshooting. Sync your projects, then look up addresses
and hosts without contacting your cloud provider.

## Features

- **GCP inventory** — Cloud NAT, external forwarding rules and Compute Engine.
- **OVH inventory** — dedicated bare-metal servers and their primary public IPv4.
- **Offline search** — find resources by IPv4 address or configured hostname,
  including wildcard host rules.
- **Readable results** — see projects, locations, resource names and relevant
  details such as load balancer hosts, ports and VM status.
- **Reliable caching** — a failed sync preserves the last successful inventory.

OVH inventory includes Manager hostnames, commercial names, regions, zones,
datacenters and server IDs. Host searches use cached provider metadata, not DNS.

## Quick start

Requires **Bash 3.2+** and **jq**. GCP synchronization also requires **gcloud**,
authenticated with permission to read the relevant Compute resources.
For OVH sync, see the optional [Python SDK setup](docs/ovh.md).

Clone this repository, then run from its directory:

```bash
# Build your local inventory
./ipwho sync --gcp-project my-project --gcp-project another-project

# Optional: include OVH in the same snapshot
./ipwho sync --gcp-project my-project --ovh

# Search it offline
./ipwho 203.0.113.10
./ipwho api.example.com
```

Each sync replaces the inventory with the selected providers and projects. Lookups use the
last successful snapshot and display its collection time. Sync prints brief
progress messages on stderr, followed by its elapsed time and cache location.

## Example

```text
Host: api.example.com
Cache generated at: 2026-11-02T15:00:00Z
GCP projects: my-project

Resource 1:
  IPv4: 203.0.113.10
  Matched rules: *.example.com
  Provider: gcp
  Type: forwarding_rule
  Project: my-project
  Name: public-https
  Location: global
  Direction: ingress
  Scheme: EXTERNAL_MANAGED
  Protocol: TCP
  Ports: 443-443
  Hosts: *.example.com
```

Use `./ipwho --help` for a summary of the available commands.

## Development

Tests use mocked cloud responses and require no cloud credentials or OVH SDK.
Python 3 is needed to run the OVH adapter tests.

```bash
for test in tests/*.sh; do bash "$test"; done
shellcheck ipwho lib/*.sh lib/providers/*.sh examples/*.sh tests/*.sh
pyright
```

The OVH Python adapter uses strict Pyright checking against Python 3.15.
GitHub Actions runs these checks on Linux and macOS without cloud credentials.

## License

[MIT](LICENSE).
