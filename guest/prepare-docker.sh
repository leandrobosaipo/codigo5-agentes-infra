#!/usr/bin/env bash
# New Ubuntu guest only. The executor verifies GitHub/CI before invoking this file.
set -euo pipefail
umask 077
mode=${1:---plan}
[[ $mode == --plan || $mode == --refresh-index || $mode == --install ]] || { echo 'Unknown mode' >&2; exit 2; }
[[ -r /etc/os-release ]] || exit 2
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || { echo 'Ubuntu 24.04 required' >&2; exit 2; }
if [[ $mode == --plan ]]; then
    printf 'mode=plan\nmachine_id=%s\n' "$(cat /etc/machine-id)"
    apt-cache policy docker.io docker-compose-v2
    exit 0
fi
[[ ${2:-} == --apply && $EUID == 0 ]] || { echo 'Root and explicit --apply required' >&2; exit 2; }
[[ ${SOURCE_COMMIT:-} =~ ^[a-f0-9]{40}$ && ${EXPECTED_SCRIPT_SHA256:-} =~ ^[a-f0-9]{64}$ ]] || exit 2
[[ $(sha256sum "$0" | cut -d ' ' -f 1) == "$EXPECTED_SCRIPT_SHA256" ]] || { echo 'Script hash mismatch' >&2; exit 2; }
[[ ${EXPECTED_MACHINE_ID:-} =~ ^[a-f0-9]{32}$ && $(cat /etc/machine-id) == "$EXPECTED_MACHINE_ID" ]] || { echo 'Guest identity mismatch' >&2; exit 2; }
[[ $(systemd-detect-virt) == microsoft ]] || { echo 'Hyper-V guest required' >&2; exit 2; }
if command -v docker >/dev/null; then echo 'Existing Docker: inspect before proceeding' >&2; exit 2; fi
(( $(df -B1 --output=avail / | tail -1) >= 8 * 1024 * 1024 * 1024 )) || { echo 'Need 8 GiB free in guest' >&2; exit 2; }
if [[ $mode == --refresh-index ]]; then
    apt-get update
    apt-cache policy docker.io docker-compose-v2
    exit 0
fi
: "${PACKAGE_CONFIG:?Versioned package JSON required}" "${EXPECTED_CONFIG_SHA256:?Config hash required}"
[[ $EXPECTED_CONFIG_SHA256 =~ ^[a-f0-9]{64}$ && $(sha256sum "$PACKAGE_CONFIG" | cut -d ' ' -f 1) == "$EXPECTED_CONFIG_SHA256" ]] || exit 2
mapfile -t versions < <(python3 - "$PACKAGE_CONFIG" <<'PY'
import json,re,sys
with open(sys.argv[1]) as f: config=json.load(f)
assert config['schema']==1
for name in ('dockerVersion','composeVersion'):
    value=config[name]
    assert isinstance(value,str) and re.fullmatch(r'[0-9][A-Za-z0-9.:+~_-]*',value)
    print(value)
PY
)
[[ ${#versions[@]} == 2 ]] || { echo 'Invalid package versions' >&2; exit 2; }
receipt_dir="/var/lib/codigo5-lab-docker-$SOURCE_COMMIT"
mkdir -m 700 "$receipt_dir" # Refuse a previous attempt instead of overwriting it.
printf 'source_commit=%s\nscript_sha256=%s\nconfig_sha256=%s\ndocker_version=%s\ncompose_version=%s\n' \
    "$SOURCE_COMMIT" "$EXPECTED_SCRIPT_SHA256" "$EXPECTED_CONFIG_SHA256" "${versions[0]}" "${versions[1]}" > "$receipt_dir/01-install-intent.txt"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "docker.io=${versions[0]}" "docker-compose-v2=${versions[1]}"
systemctl enable --now docker
docker version --format '{{.Server.Version}}' > "$receipt_dir/docker-version.txt"
docker compose version > "$receipt_dir/compose-version.txt"
dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$receipt_dir/packages.tsv"
# Official hello-world linux/amd64 manifest resolved from Docker Registry on 2026-11-05.
image='docker.io/library/hello-world@sha256:d1a8d0a4eeb63aff09f5f34d4d80505e0ba81905f36158cc3970d8e07179e59e'
docker pull "$image"
container=$(docker create --name "codigo5-smoke-${SOURCE_COMMIT:0:12}" --label codigo5.project=agentes-infra \
    --network none --memory 32m --cpus 0.25 --read-only --cap-drop ALL --security-opt no-new-privileges "$image")
printf '%s\n' "$container" > "$receipt_dir/container-id.txt"
docker start --attach "$container" > "$receipt_dir/smoke-stdout.txt"
docker inspect "$container" > "$receipt_dir/container-inspect.json"
python3 - "$receipt_dir" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); obj=json.loads((p/'container-inspect.json').read_text())[0]
assert obj['State']['ExitCode']==0 and not obj['State']['Running']
assert 'Hello from Docker!' in (p/'smoke-stdout.txt').read_text()
with (p/'02-verified.json').open('x') as f:
    json.dump({'state':'docker-smoke-verified','containerId':obj['Id'],'imageId':obj['Image'],
               'networkMode':obj['HostConfig']['NetworkMode'],'exitCode':0},f,indent=2)
PY
printf 'Verified Docker/Compose and synthetic container; receipts=%s\n' "$receipt_dir"
