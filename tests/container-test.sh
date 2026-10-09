#!/usr/bin/env bash
# shellcheck shell=bash
# Runs install.sh inside fresh Proxmox test containers (a three-scenario matrix), validates each result, and removes the containers.
# Usage: tests/container-test.sh [--scenario random|node-name|fqdn] [--keep] [--help]
# Env:   PROXMOX_TEST_IMAGE (default rtedpro/proxmox:latest), PROXMOX_TEST_TIMEOUT seconds per install run (default 1800),
#        PROXMOX_TEST_HOSTNAME pins the base short hostname so a failing run can be reproduced

set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR%/*}/install.sh"
IMAGE="${PROXMOX_TEST_IMAGE:-rtedpro/proxmox:latest}"
INSTALL_TIMEOUT="${PROXMOX_TEST_TIMEOUT:-1800}"
SCENARIOS="random node-name fqdn"
KEEP_ALL=false
WORK_DIR=""
CONTAINERS=()
KEEP_CONTAINERS=()
PASS_COUNT=0
FAIL_COUNT=0
SCENARIO_FAILS=0
CONTAINER=""
SCENARIO_DIR=""
EXPECTED_NODE=""

__usage() {
	cat <<-EOF
		Usage: tests/container-test.sh [--scenario NAME] [--keep] [--help]

		Runs install.sh in a fresh ${IMAGE} container per scenario. Each
		scenario runs install.sh twice (the second run checks idempotency),
		then runs the validation checks. Hostnames are random so the test
		does not only pass for the name baked into the image.

		Scenarios:
		  random     random short hostname, node name follows the hostname
		  node-name  random hostname plus a different PVE_NODE_NAME (rename path)
		  fqdn       random hostname that is already a fully qualified name

		  --scenario NAME  Run only one scenario
		  --keep           Leave containers and logs in place
		  --help           Show this help

		Environment:
		  PROXMOX_TEST_IMAGE     Test image (default rtedpro/proxmox:latest)
		  PROXMOX_TEST_TIMEOUT   Seconds allowed per install run (default 1800)
		  PROXMOX_TEST_HOSTNAME  Pin the base short hostname for reproducing a failure
	EOF
}

__random_label() {
	printf 'pve-%07x' $((RANDOM * 32768 + RANDOM))
}

__cleanup() {
	local name keep kept
	for name in "${CONTAINERS[@]}"; do
		kept=false
		for keep in "${KEEP_CONTAINERS[@]}"; do
			[ "$keep" = "$name" ] && kept=true
		done
		if ! $KEEP_ALL && ! $kept; then
			docker rm -f "$name" >/dev/null 2>&1 || true
		fi
	done
	if [ -n "$WORK_DIR" ] && ! $KEEP_ALL && [ "${#KEEP_CONTAINERS[@]}" -eq 0 ]; then
		rm -rf "$WORK_DIR"
	fi
}

__record() {
	local name="$1" rc="$2"
	if [ "$rc" -eq 0 ]; then
		PASS_COUNT=$((PASS_COUNT + 1))
		printf 'PASS  %s\n' "$name"
	else
		FAIL_COUNT=$((FAIL_COUNT + 1))
		SCENARIO_FAILS=$((SCENARIO_FAILS + 1))
		printf 'FAIL  %s\n' "$name"
	fi
}

# Runs a command inside the current container with @NODE@ replaced by the expected node name, bounded by a timeout
__check() {
	local name="$1" cmd="$2"
	cmd="${cmd//@NODE@/$EXPECTED_NODE}"
	timeout 120 docker exec "$CONTAINER" bash -c "$cmd" >>"${SCENARIO_DIR}/checks.log" 2>&1
	__record "$name" "$?"
}

__wait_for_systemd() {
	local state
	for _ in $(seq 1 60); do
		state="$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)"
		case "$state" in
		running | degraded) return 0 ;;
		esac
		sleep 2
	done
	return 1
}

__run_install() {
	local label="$1" log="$2" node_name="$3"
	local env_args=(-e AUTO_DIST_UPGRADE=no -e DOWNLOAD_ISOS=no -e DOWNLOAD_TEMPLATES=no -e RUN_PROXMENUX=no)
	[ -z "$node_name" ] || env_args+=(-e "PVE_NODE_NAME=${node_name}")
	timeout "$INSTALL_TIMEOUT" docker exec "${env_args[@]}" "$CONTAINER" bash /root/install.sh >"$log" 2>&1
	__record "$label" "$?"
}

# Args: scenario name, container hostname, PVE_NODE_NAME (empty for none), expected node name
__run_scenario() {
	local name="$1" container_host="$2" node_name="$3" resolve_cmd hosts_cmd
	EXPECTED_NODE="$4"
	CONTAINER="proxmox-test-${WORK_DIR##*-}-${name}"
	SCENARIO_DIR="${WORK_DIR}/${name}"
	SCENARIO_FAILS=0
	mkdir -p "$SCENARIO_DIR"
	CONTAINERS+=("$CONTAINER")

	printf '\n== scenario %s: hostname=%s PVE_NODE_NAME=%s expected node=%s\n' "$name" "$container_host" "${node_name:-<unset>}" "$EXPECTED_NODE"
	printf 'hostname=%s\nPVE_NODE_NAME=%s\n' "$container_host" "$node_name" >"${SCENARIO_DIR}/scenario.env"

	if ! timeout 120 docker run -d --name "$CONTAINER" --hostname "$container_host" --privileged "$IMAGE" >/dev/null; then
		__record "${name}: container starts" 1
		return 1
	fi
	__wait_for_systemd
	__record "${name}: container reaches systemd running state" "$?"
	if [ "$SCENARIO_FAILS" -ne 0 ]; then
		KEEP_CONTAINERS+=("$CONTAINER")
		return 1
	fi

	docker cp "$INSTALL_SCRIPT" "${CONTAINER}:/root/install.sh"

	__check "${name}: bash -n install.sh" "bash -n /root/install.sh"
	__run_install "${name}: install.sh first run" "${SCENARIO_DIR}/install-1.log" "$node_name"
	__run_install "${name}: install.sh second run (idempotent)" "${SCENARIO_DIR}/install-2.log" "$node_name"

	# shellcheck disable=SC2016
	__check "${name}: hostname matches the node name" '[ "$(hostname -s)" = "@NODE@" ]'
	# shellcheck disable=SC2016
	resolve_cmd='ip="$(getent hosts "@NODE@" | awk "{print \$1; exit}")"'
	resolve_cmd="${resolve_cmd}; [ -n \"\$ip\" ] && [ \"\${ip#127.}\" = \"\$ip\" ] && [ \"\$ip\" != \"::1\" ]"
	__check "${name}: node name resolves to a non-loopback IP" "$resolve_cmd"
	# Wildcard DNS can make any name resolve, so also require the entry in /etc/hosts itself
	# shellcheck disable=SC2016
	hosts_cmd='awk -v n="@NODE@" '"'"'$1 !~ /^#/ && $1 !~ /^127\./ && $1 != "::1" { for (i = 2; i <= NF; i++) if ($i == n) f = 1 } END { exit !f }'"'"' /etc/hosts'
	__check "${name}: /etc/hosts maps the node name to a non-loopback IP" "$hosts_cmd"
	__check "${name}: pve-cluster is active" "systemctl is-active --quiet pve-cluster"
	__check "${name}: /etc/pve/nodes/@NODE@ exists" "[ -d /etc/pve/nodes/@NODE@ ]"
	__check "${name}: Proxmox certificate and key exist" "[ -f /etc/pve/local/pve-ssl.pem ] && [ -f /etc/pve/local/pve-ssl.key ]"
	__check "${name}: nft -c -f /etc/nftables.conf" "nft -c -f /etc/nftables.conf"
	__check "${name}: named-checkconf" "named-checkconf /etc/bind/named.conf"
	__check "${name}: dhcpd -t" "dhcpd -t -cf /etc/dhcp/dhcpd.conf"
	__check "${name}: radvd config check" "radvd -C /etc/radvd.conf -n -c"
	__check "${name}: nginx -t" "nginx -t"
	local service
	for service in bind9 isc-dhcp-server radvd nftables nginx; do
		__check "${name}: service ${service} is active" "systemctl is-active --quiet ${service}"
	done

	if [ "$SCENARIO_FAILS" -ne 0 ]; then
		KEEP_CONTAINERS+=("$CONTAINER")
		printf 'scenario %s failed; container %s kept\n' "$name" "$CONTAINER"
	fi
}

__main() {
	local arg only=""
	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
		--keep) KEEP_ALL=true ;;
		--scenario)
			only="${2:-}"
			shift
			;;
		--help | -h)
			__usage
			return 0
			;;
		*)
			__usage >&2
			return 2
			;;
		esac
		shift
	done
	if [ -n "$only" ]; then
		case " $SCENARIOS " in
		*" $only "*) SCENARIOS="$only" ;;
		*)
			echo "Unknown scenario: ${only}" >&2
			return 2
			;;
		esac
	fi

	command -v docker >/dev/null 2>&1 || {
		echo "docker is required" >&2
		return 1
	}
	[ -f "$INSTALL_SCRIPT" ] || {
		echo "install.sh not found at ${INSTALL_SCRIPT}" >&2
		return 1
	}

	mkdir -p "${TMPDIR:-/tmp}/scriptmgr"
	WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scriptmgr/proxmox-XXXXXX")"
	trap __cleanup EXIT
	printf 'Image: %s\nLogs: %s\n' "$IMAGE" "$WORK_DIR"

	timeout 600 docker pull "$IMAGE" >"${WORK_DIR}/pull.log" 2>&1 || {
		echo "Could not pull ${IMAGE}; see ${WORK_DIR}/pull.log" >&2
		KEEP_CONTAINERS+=("none")
		return 1
	}

	local base other scenario
	for scenario in $SCENARIOS; do
		base="${PROXMOX_TEST_HOSTNAME:-$(__random_label)}"
		other="$(__random_label)"
		case "$scenario" in
		random) __run_scenario random "$base" "" "$base" ;;
		node-name) __run_scenario node-name "$base" "$other" "$other" ;;
		fqdn) __run_scenario fqdn "${base}.lab-${other#pve-}.test" "" "$base" ;;
		esac
	done

	printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
	if [ "$FAIL_COUNT" -ne 0 ]; then
		printf 'Logs kept in %s\n' "$WORK_DIR"
		return 1
	fi
	return 0
}

__main "$@"
