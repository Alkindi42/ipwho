# ipwho

**Find the cloud resource behind a public IP or configured hostname.**

`ipwho` is a lightweight Bash CLI for building a local cloud inventory and
searching it during troubleshooting. Sync your projects, then look up addresses
and hosts without contacting your cloud provider.

## Features

- **GCP inventory** — Cloud NAT, external forwarding rules and Compute Engine.
- **Offline search** — find resources by IPv4 address or configured hostname,
  including wildcard host rules.
- **Readable results** — see projects, locations, resource names and relevant
  details such as load balancer hosts, ports and VM status.
- **Reliable caching** — a failed sync preserves the last successful inventory.

GCP is currently the only supported provider. Host searches use cached routing
rules, not DNS resolution.

## Quick start

Requires **Bash 3.2+** and **jq**. Synchronization also requires **gcloud**,
authenticated with permission to read the relevant Compute resources.

Clone this repository, then run from its directory:

```bash
# Build your local inventory
./ipwho sync --gcp-project my-project --gcp-project another-project

# Search it offline
./ipwho 203.0.113.10
./ipwho api.example.com
```

Each sync replaces the inventory with the selected projects. Lookups use the
last successful snapshot and display its collection time.

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

Tests use mocked cloud responses and require no cloud credentials.

```bash
for test in tests/*.sh; do bash "$test"; done
shellcheck ipwho lib/*.sh lib/providers/*.sh examples/*.sh tests/*.sh
```

## License

[MIT](LICENSE).
