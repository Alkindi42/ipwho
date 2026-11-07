# OVH dedicated servers

OVH synchronization uses the [official Python SDK](https://github.com/ovh/python-ovh).
It collects dedicated servers only: their primary IPv4, Manager display name,
commercial name, region, availability zone, datacenter and server ID.
Additional/Failover IPs are not collected.

## Setup

Python 3.10+ is required only for OVH sync. From the repository directory:

```bash
python3 -m venv "$HOME/.local/share/ipwho/ovh-venv"
"$HOME/.local/share/ipwho/ovh-venv/bin/python" -m pip install -r requirements-ovh.txt
export IPWHO_OVH_PYTHON="$HOME/.local/share/ipwho/ovh-venv/bin/python"
```

Configure authentication using the SDK's standard environment variables or
`~/.ovh.conf`. The SDK supports both application credentials with a consumer key
and OAuth2 service accounts. See its
[configuration documentation](https://github.com/ovh/python-ovh#configuration).
Use the appropriate endpoint for your account, such as `ovh-eu`.

Only read access to these endpoints is needed:

```text
GET /dedicated/server
GET /dedicated/server/{serviceName}
GET /dedicated/server/{serviceName}/specifications/hardware
```

Keep credentials outside the repository and protect the configuration file with
private permissions. `ipwho` neither creates credentials nor includes them in
its cache. It never requests rescue credentials, billing details or server tasks.

## Usage

```bash
# OVH only
./ipwho sync --ovh

# One complete GCP + OVH snapshot
./ipwho sync --gcp-project my-project --ovh

# Offline lookup, with no Python/SDK requirement
./ipwho server.example.com
```

Every sync replaces the entire cache. Include all desired providers and projects
in the same invocation. Your personal GCP launcher is not changed automatically.

The Manager display name is used as the resource name and, when it is a valid
hostname, as a cached hostname. Arbitrary labels and wildcards are not host rules.
Missing display names fall back to the OVH service name, without inventing a
hostname association. Missing optional location or commercial metadata remains
unknown rather than being inferred. Only the selected metadata is cached.
