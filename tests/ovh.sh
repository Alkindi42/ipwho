#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
export IPWHO_TEST_BASH="$BASH"

# The SDK and gcloud are mocked; no SDK installation, credentials or cloud access are used.
python3 -B - <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

root = Path(os.environ['ROOT_DIR'])
with tempfile.TemporaryDirectory(prefix='ipwho-ovh-test-') as temporary:
    work = Path(temporary)
    sdk = work / 'sdk'
    sdk.mkdir()
    (sdk / 'ovh.py').write_text('''import json, os
if os.environ.get("OVH_TEST_CASE") == "import-failure":
    raise RuntimeError("never-print-this")
class Client:
    def __init__(self):
        if os.environ.get("OVH_TEST_CASE") == "configuration-failure":
            raise RuntimeError("never-print-this")
    def get(self, path):
        with open(os.environ["OVH_TEST_CALLS"], "a") as log:
            log.write(path + "\\n")
        case = os.environ.get("OVH_TEST_CASE", "success")
        if path == "/dedicated/server":
            if case == "list-failure": raise RuntimeError("never-print-this")
            if case == "empty": return []
            if case == "bad-list": return {}
            if case == "bad-service-name": return [1]
            return ["service-a.example.com", "service-b.example.com", "service-a.example.com"]
        suffix = "/specifications/hardware"
        if path.endswith(suffix):
            if case == "hardware-failure": raise RuntimeError("never-print-this")
            if case == "bad-hardware-object": return []
            return {"description": "Baremetal model" if "service-a" in path else None,
                    "extra": "must-not-be-cached"}
        if path not in ("/dedicated/server/service-a.example.com", "/dedicated/server/service-b.example.com"):
            raise RuntimeError("Unexpected API path")
        if case == "server-failure": raise RuntimeError("never-print-this")
        if case == "bad-server-object": return []
        primary = "service-a" in path
        server = {"name":path.rsplit("/", 1)[-1],
                  "ip":"203.0.113.10" if primary else "203.0.113.11",
                  "serverId":1234567890123456789 if primary else 2,
                  "iam":{"displayName":"SERVER.EXAMPLE.COM." if primary else None},
                  "region":"region-a" if primary else "region-b",
                  "availabilityZone":"zone-a" if primary else None,
                  "datacenter":"dc-a" if primary else "dc-b",
                  "commercialRange":"not-the-commercial-name",
                  "bootScript":"must-not-be-cached"}
        if case == "ipv6" and not primary: server["ip"] = "2001:db8::1"
        if case == "bad-ip": server["ip"] = None
        if case == "bad-ip-value": server["ip"] = "not-an-address"
        if case == "empty-name": server["name"] = ""
        if case == "bad-id": server["serverId"] = None
        if case == "bad-id-value": server["serverId"] = "not-a-number"
        if case == "bool-id": server["serverId"] = True
        if case == "float-id": server["serverId"] = 1.5
        if case == "missing-iam": server["iam"] = None
        if case == "bad-iam": server["iam"] = []
        if case == "bad-display-name": server["iam"]["displayName"] = {}
        if case == "bad-location": server["region"] = {}
        if case == "wildcard-display-name": server["iam"]["displayName"] = "*.example.com"
        return server
''')
    bin_dir = work / 'bin'
    bin_dir.mkdir()
    (bin_dir / 'gcloud').write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$OVH_TEST_GCP_CALLS"
if [[ "${OVH_TEST_CASE:-}" == gcp-failure ]]; then
  printf 'Mock GCP failure\\n' >&2
  exit 1
fi
case "$1 $2 $3" in
  'compute routers list'|'compute forwarding-rules list') printf '[]\\n' ;;
  'compute instances list') printf '[{"name":"vm","id":"1","zone":"region-a-b","networkInterfaces":[{"name":"nic0","accessConfigs":[{"natIP":"203.0.113.10"}]}]}]\\n' ;;
  *) exit 1 ;;
esac
''')
    (bin_dir / 'gcloud').chmod(0o755)
    env = dict(os.environ, HOME=str(work / 'home'), XDG_CACHE_HOME=str(work / 'cache'),
               PYTHONPATH=str(sdk), PYTHONDONTWRITEBYTECODE='1',
               IPWHO_OVH_PYTHON=sys.executable, OVH_TEST_CASE='success',
               OVH_TEST_CALLS=str(work / 'ovh-calls'), OVH_TEST_GCP_CALLS=str(work / 'gcp-calls'),
               PATH=str(bin_dir)+os.pathsep+os.environ['PATH'])
    cache = work / 'cache/ipwho/cache.json'

    def run(args, expected=0, case='success', overrides=None):
        for file in ('ovh-calls', 'gcp-calls'):
            if (work / file).exists():
                (work / file).unlink()
        settings = dict(env, OVH_TEST_CASE=case)
        if overrides: settings.update(overrides)
        proc = subprocess.run([os.environ['IPWHO_TEST_BASH'], str(root / 'ipwho'), *args],
                              env=settings, text=True, capture_output=True)
        assert proc.returncode == expected, (args, case, proc.returncode, proc.stderr)
        assert 'never-print-this' not in proc.stderr
        if args[0] == 'sync': assert not proc.stdout
        return proc

    run(['sync', '--ovh', '--ovh'])
    data = json.loads(cache.read_text())
    assert data['version'] == 1
    assert data['scope'] == {'ovh': {'dedicated_servers': True}}
    assert len(data['resources']) == 2
    server = data['resources']['203.0.113.10'][0]
    assert server['provider'] == 'ovh' and server['type'] == 'dedicated_server'
    assert server['resource'] == {'name':'SERVER.EXAMPLE.COM.', 'id':'1234567890123456789',
                                  'service_name':'service-a.example.com'}
    assert server['commercial_name'] == 'Baremetal model'
    assert server['region'] == 'region-a' and server['zone'] == 'zone-a'
    assert server['datacenter'] == 'dc-a' and server['location'] == 'zone-a'
    assert server['hosts'] == ['SERVER.EXAMPLE.COM.'] and 'project' not in server
    fallback = data['resources']['203.0.113.11'][0]
    assert fallback['resource']['name'] == 'service-b.example.com'
    assert fallback['hosts'] == [] and fallback['commercial_name'] is None
    assert fallback['location'] == 'region-b'
    assert 'must-not-be-cached' not in cache.read_text()
    calls = (work / 'ovh-calls').read_text().splitlines()
    assert len(calls) == 5 and len(set(calls)) == 5, calls
    assert not (work / 'gcp-calls').exists()
    print('PASS: OVH-only inventory, display names, commercial names, locations and lossless IDs')

    proc = run(['server.example.com'], overrides={'IPWHO_OVH_PYTHON':'/nonexistent/python'})
    for line in ('Host: server.example.com', 'OVH: dedicated servers',
                 'Service name: service-a.example.com', 'Commercial name: Baremetal model',
                 'Region: region-a', 'Zone: zone-a', 'Datacenter: dc-a',
                 'ID: 1234567890123456789'):
        assert line in proc.stdout, (line, proc.stdout)
    assert 'GCP projects:' not in proc.stdout
    assert not (work / 'ovh-calls').exists() and not (work / 'gcp-calls').exists()
    run(['service-b.example.com'], expected=1)
    print('PASS: OVH host lookup remains offline and does not invent missing hostnames')

    run(['sync', '--gcp-project', 'test-project', '--ovh'])
    data = json.loads(cache.read_text())
    assert data['scope'] == {'gcp':{'projects':['test-project']}, 'ovh':{'dedicated_servers':True}}
    assert len(data['resources']['203.0.113.10']) == 2
    assert {r['provider'] for r in data['resources']['203.0.113.10']} == {'gcp','ovh'}
    assert len((work / 'gcp-calls').read_text().splitlines()) == 3
    print('PASS: combined GCP/OVH snapshot aggregates resources sharing an IPv4')

    previous = cache.read_bytes()
    failures = {
        'import-failure': 'RuntimeError',
        'configuration-failure': 'RuntimeError',
        'list-failure': 'RuntimeError',
        'bad-list': 'TypeError',
        'bad-service-name': 'TypeError',
        'server-failure': 'RuntimeError',
        'bad-server-object': 'TypeError',
        'hardware-failure': 'RuntimeError',
        'bad-hardware-object': 'TypeError',
        'bad-ip': 'TypeError',
        'bad-ip-value': 'ValueError',
        'empty-name': 'ValueError',
        'bad-id': 'TypeError',
        'bad-id-value': 'ValueError',
        'bool-id': 'TypeError',
        'float-id': 'TypeError',
        'bad-iam': 'TypeError',
        'bad-display-name': 'TypeError',
        'bad-location': 'TypeError',
        'gcp-failure': None,
    }
    for case, error_type in failures.items():
        proc = run(['sync', '--gcp-project', 'test-project', '--ovh'], expected=1, case=case)
        if error_type is not None:
            assert f'({error_type})' in proc.stderr, (case, proc.stderr)
        assert cache.read_bytes() == previous, case
        assert not list(cache.parent.glob('.cache.*'))
        if case == 'gcp-failure': assert not (work / 'ovh-calls').exists()
    print('PASS: API/configuration/data failures preserve the previous cache and redact exceptions')

    run(['sync', '--ovh'], case='missing-iam')
    assert all(r['hosts'] == [] and r['resource']['name'] == r['resource']['service_name']
               for rows in json.loads(cache.read_text())['resources'].values() for r in rows)
    print('PASS: missing IAM metadata falls back to the service name without creating a hostname')

    run(['sync', '--ovh'], case='wildcard-display-name')
    assert all(r['hosts'] == [] for rows in json.loads(cache.read_text())['resources'].values() for r in rows)
    run(['server.example.com'], expected=1)
    print('PASS: OVH display labels are not interpreted as load-balancer wildcard rules')

    run(['sync', '--ovh'], case='ipv6')
    assert list(json.loads(cache.read_text())['resources']) == ['203.0.113.10']
    assert not any('service-b' in line and 'hardware' in line for line in (work / 'ovh-calls').read_text().splitlines())
    run(['sync', '--ovh'], case='empty')
    assert json.loads(cache.read_text())['resources'] == {}
    print('PASS: primary IPv4 only, no Additional IP requests, and empty successful snapshots')

    run(['sync', '--gcp-project', 'test-project'], overrides={'IPWHO_OVH_PYTHON':'/nonexistent/python'})
    assert not (work / 'ovh-calls').exists()
    assert json.loads(cache.read_text())['scope'] == {'gcp':{'projects':['test-project']}}
    run(['sync', '--ovh', '--gcp-project'], expected=2)
    assert not (work / 'ovh-calls').exists() and not (work / 'gcp-calls').exists()
    print('PASS: GCP-only sync needs no OVH dependencies and invalid flags fail before collection')

    no_sdk = work / 'no-sdk'
    no_sdk.write_text('#!/usr/bin/env bash\nexec '+shlex.quote(sys.executable)+' -S "$@"\n')
    no_sdk.chmod(0o755)
    previous = cache.read_bytes()
    proc = run(['sync', '--ovh'], expected=1,
               overrides={'IPWHO_OVH_PYTHON':str(no_sdk), 'PYTHONPATH':''})
    assert 'ovh Python SDK' in proc.stderr and cache.read_bytes() == previous
    print('PASS: missing optional SDK fails clearly without replacing the cache')

    no_output = work / 'no-output'
    no_output.write_text('#!/usr/bin/env bash\nexit 0\n')
    no_output.chmod(0o755)
    run(['sync', '--ovh'], expected=1, overrides={'IPWHO_OVH_PYTHON':str(no_output)})
    assert cache.read_bytes() == previous
    print('PASS: an empty adapter response is rejected, not published as an empty inventory')
PY
