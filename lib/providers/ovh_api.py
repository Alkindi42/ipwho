#!/usr/bin/env python3
"""Read dedicated-server metadata using OVH's official SDK."""

from __future__ import annotations

import ipaddress
import json
import sys
from collections.abc import Mapping
from importlib import import_module
from typing import Protocol, TypedDict, cast
from urllib.parse import quote


class OVHClient(Protocol):
    def get(self, path: str) -> object: ...


class ServerMetadata(TypedDict):
    """Minimal API payload consumed by the Bash collector."""

    name: str
    displayName: str | None
    serverId: str
    ip: str
    region: str | None
    availabilityZone: str | None
    datacenter: str | None
    commercialName: str | None


class CollectionError(Exception):
    """A collection error whose message is safe to display."""


def _as_object(value: object) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise TypeError("Invalid API object")
    # JSON object keys are strings; values must still be validated individually.
    return cast(Mapping[str, object], value)


def _required_string(value: object) -> str:
    if not isinstance(value, str):
        raise TypeError("Expected a string")
    if not value:
        raise ValueError("Required string must not be empty")
    return value


def _optional_string(value: object) -> str | None:
    if value is not None and not isinstance(value, str):
        raise TypeError("Expected a string or None")
    return value


def collect_servers(client: OVHClient) -> list[ServerMetadata]:
    response = client.get("/dedicated/server")
    if not isinstance(response, list):
        raise TypeError("Invalid dedicated-server list")
    services = [_required_string(item) for item in cast(list[object], response)]

    result: list[ServerMetadata] = []
    for service in dict.fromkeys(services):
        path = f"/dedicated/server/{quote(service, safe='')}"
        try:
            server = _as_object(client.get(path))
            address = ipaddress.ip_address(_required_string(server.get("ip")))
            if address.version != 4:
                continue

            server_id = server.get("serverId")
            # bool is an int subclass, but is not a valid server ID.
            if isinstance(server_id, bool) or not isinstance(server_id, (int, str)):
                raise TypeError("Invalid server ID type")
            if not str(server_id).isdigit():
                raise ValueError("Invalid server ID")

            name = _required_string(server.get("name"))
            iam_value = server.get("iam")
            iam: Mapping[str, object] = (
                {} if iam_value is None else _as_object(iam_value)
            )
            display_name = _optional_string(iam.get("displayName"))
            region = _optional_string(server.get("region"))
            zone = _optional_string(server.get("availabilityZone"))
            datacenter = _optional_string(server.get("datacenter"))

            path = f"{path}/specifications/hardware"
            hardware = _as_object(client.get(path))
            commercial_name = _optional_string(hardware.get("description"))

            # Whitelist metadata: never emit rescue settings, keys or billing data.
            result.append(
                {
                    "name": name,
                    "displayName": display_name,
                    "serverId": str(server_id),
                    "ip": str(address),
                    "region": region,
                    "availabilityZone": zone,
                    "datacenter": datacenter,
                    "commercialName": commercial_name,
                }
            )
        except Exception as error:
            # SDK exception messages can contain sensitive response/configuration data.
            raise CollectionError(
                f"OVH read failed at {path} ({type(error).__name__})"
            ) from None
    return result


def main() -> int:
    try:
        sdk = import_module("ovh")
        client = cast(OVHClient, sdk.Client())
        servers = collect_servers(client)
    except ImportError:
        print(
            "Error: OVH sync requires the ovh Python SDK; see README.md.",
            file=sys.stderr,
        )
        return 1
    except CollectionError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(
            f"Error: OVH collection failed ({type(error).__name__}); "
            "check configuration and read permissions.",
            file=sys.stderr,
        )
        return 1
    print(json.dumps(servers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
