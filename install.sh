#!/usr/bin/env bash
################################################################################
# Proxmox VE Bootstrap Script
# Version: 3.0.0
# Description: Complete Proxmox VE setup with networking, DHCP, DNS, and SDN
# Supports: Proxmox VE 7.x, 8.x, 9.x
# License: MIT
################################################################################

set -euo pipefail

################################################################################
# CONFIGURATION VARIABLES
################################################################################

SCRIPT_VERSION="3.0.0"
CONFIG_FILE="/etc/proxmox-bootstrap.conf"
ENV_FILE="./.env"
LOG_DIR="/var/log/proxmox-bootstrap"
LOG_FILE="${LOG_DIR}/bootstrap.log"
BACKUP_BASE_DIR="/mnt/Backups/proxmox"
BACKUP_DIR="${BACKUP_BASE_DIR}/$(date +%Y%m%d_%H%M%S)"
STATE_FILE="/var/lib/proxmox-bootstrap-state"
RESOLVED_NETWORK_STATE_FILE="${STATE_FILE}.network"
OPTIONAL_TOOLS_DIR="/usr/local/share/proxmox-bootstrap/tools"
PROXMENUX_INSTALLER_URL="https://raw.githubusercontent.com/MacRimi/ProxMenux/main/install_proxmenux.sh"
COMMUNITY_POST_INSTALL_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh"
ORIGINAL_ENV_KEYS="$(env | awk -F= '{print $1}')"
SUMMARY_LINES=()

WAN_NIC="${WAN_NIC:-}"
LAN_NIC="${LAN_NIC:-}"
ROUTER_NIC="${ROUTER_NIC:-}"
WAN_BR="${WAN_BR:-vmbr0}"
LAN_BR="${LAN_BR:-vmbr1}"
ROUTER_BR="${ROUTER_BR:-}"

WAN_V4="${WAN_V4:-}"
WAN_V4_GW="${WAN_V4_GW:-}"
WAN_V4_BRD="${WAN_V4_BRD:-}"
WAN_V4_IP="${WAN_V4_IP:-}"

WAN_V6="${WAN_V6:-}"
WAN_V6_GW="${WAN_V6_GW:-}"

LAN_V4="${LAN_V4:-192.168.251.1/24}"
LAN_V4_IP="${LAN_V4_IP:-}"
LAN_V4_BRD="${LAN_V4_BRD:-}"
LAN_V4_NET="${LAN_V4_NET:-}"
DHCP_V4_START="${DHCP_V4_START:-}"
DHCP_V4_END="${DHCP_V4_END:-}"
LAN_DOMAIN="${LAN_DOMAIN:-}"

LAN_V6_PREFIX="${LAN_V6_PREFIX:-}"
LAN_V6_ROUTER_IP="${LAN_V6_ROUTER_IP:-}"
LAN_V6_STATEFUL="${LAN_V6_STATEFUL:-no}"
LAN_V6_RANGE_LOW="${LAN_V6_RANGE_LOW:-}"
LAN_V6_RANGE_HIGH="${LAN_V6_RANGE_HIGH:-}"
LAN_IPV6_IS_ULA="${LAN_IPV6_IS_ULA:-yes}"
NAT66_ENABLE="${NAT66_ENABLE:-yes}"

FWD1="${FWD1:-1.1.1.1}"
FWD2="${FWD2:-8.8.8.8}"
FWD3="${FWD3:-4.4.4.4}"

MAIL_RELAY_HOST="${MAIL_RELAY_HOST:-${SMTP_RELAY:-}}"
MAIL_RELAY_PORT="${MAIL_RELAY_PORT:-${SMTP_PORT:-587}}"
ROOT_MAIL_FORWARD="${ROOT_MAIL_FORWARD:-${ROOT_EMAIL:-root@localhost}}"
SMTP_RELAY="$MAIL_RELAY_HOST"
SMTP_PORT="$MAIL_RELAY_PORT"
ROOT_EMAIL="$ROOT_MAIL_FORWARD"

CONFIGURE_POSTFIX="${CONFIGURE_POSTFIX:-yes}"
POSTFIX_SERVER_TYPE="${POSTFIX_SERVER_TYPE:-local}"
POSTFIX_SMTP_RELAY="${POSTFIX_SMTP_RELAY:-}"
POSTFIX_SMTP_PORT="${POSTFIX_SMTP_PORT:-}"
POSTFIX_FROM_EMAIL="${POSTFIX_FROM_EMAIL:-root@localhost}"
POSTFIX_FROM_NAME="${POSTFIX_FROM_NAME:-Proxmox}"
POSTFIX_ROOT_FORWARD="${POSTFIX_ROOT_FORWARD:-root@localhost}"
POSTFIX_MYHOSTNAME="${POSTFIX_MYHOSTNAME:-}"
POSTFIX_MYDOMAIN="${POSTFIX_MYDOMAIN:-}"
POSTFIX_RELAY_TLS="${POSTFIX_RELAY_TLS:-}"
POSTFIX_RELAY_USERNAME="${POSTFIX_RELAY_USERNAME:-}"
POSTFIX_RELAY_PASSWORD="${POSTFIX_RELAY_PASSWORD:-}"
POSTFIX_WAN_ENABLE="${POSTFIX_WAN_ENABLE:-no}"
POSTFIX_FORWARD_HOST="${POSTFIX_FORWARD_HOST:-}"
POSTFIX_FORWARD_PORTS="${POSTFIX_FORWARD_PORTS:-25,465,587,110,995,143,993}"

DNS_SERVER_TYPE="${DNS_SERVER_TYPE:-local}"
DNS_FORWARD_HOST="${DNS_FORWARD_HOST:-}"
DNS_FORWARD_PORTS="${DNS_FORWARD_PORTS:-53}"
DNS_SPLIT_ENABLE="${DNS_SPLIT_ENABLE:-no}"
DNS_WAN_ENABLE="${DNS_WAN_ENABLE:-no}"
DNS_WAN_ZONE="${DNS_WAN_ZONE:-}"
DNS_WAN_RECORDS_FILE="${DNS_WAN_RECORDS_FILE:-}"
DNS_LAN_RECURSION="${DNS_LAN_RECURSION:-yes}"
DNS_WAN_RECURSION="${DNS_WAN_RECURSION:-no}"

DHCP_SERVER_TYPE="${DHCP_SERVER_TYPE:-local}"
DHCP_RELAY_HOST="${DHCP_RELAY_HOST:-}"
DHCP_RELAY_INTERFACES="${DHCP_RELAY_INTERFACES:-}"
RA_SERVER_TYPE="${RA_SERVER_TYPE:-local}"

DISABLE_SUBSCRIPTION_NAG="${DISABLE_SUBSCRIPTION_NAG:-yes}"
PVE_NODE_NAME="${PVE_NODE_NAME:-}"
FORCE_NODE_RENAME="${FORCE_NODE_RENAME:-no}"
GUEST_DEFAULT_BRIDGE="${GUEST_DEFAULT_BRIDGE:-}"
AUTO_DIST_UPGRADE="${AUTO_DIST_UPGRADE:-yes}"
PIN_NEWEST_PVE_KERNEL="${PIN_NEWEST_PVE_KERNEL:-yes}"
PVE_KERNEL_KEEP_COUNT="${PVE_KERNEL_KEEP_COUNT:-2}"
ENABLE_NESTED_VIRT="${ENABLE_NESTED_VIRT:-yes}"

DOWNLOAD_ISOS="${DOWNLOAD_ISOS:-no}"
DOWNLOAD_TEMPLATES="${DOWNLOAD_TEMPLATES:-no}"
RUN_PROXMENUX="${RUN_PROXMENUX:-no}"
RUN_POST_INSTALL="${RUN_POST_INSTALL:-no}"
CONFIGURE_SDN="${CONFIGURE_SDN:-no}"

FORCE_MODE=false
CLEAR_STATE_TASK=""

PVE_MAJOR_VERSION=""
DEBIAN_CODENAME=""
SINGLE_NIC_MODE=false

################################################################################
# LOGGING FUNCTIONS
################################################################################

log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

	echo "[${timestamp}] [${level}] ${msg}" >>"${LOG_FILE}"

	case "$level" in
	ERROR | FATAL)
		echo -e "\033[0;31m[${level}] ${msg}\033[0m" >&2
		;;
	WARN)
		echo -e "\033[0;33m[${level}] ${msg}\033[0m"
		;;
	SUCCESS)
		echo -e "\033[0;32m[${level}] ${msg}\033[0m"
		;;
	*)
		echo "[${level}] ${msg}"
		;;
	esac
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_success() { log SUCCESS "$@"; }
log_fatal() {
	log FATAL "$@"
	exit 1
}

add_summary() {
	SUMMARY_LINES+=("$*")
}

print_summary() {
	[ "${#SUMMARY_LINES[@]}" -gt 0 ] || return 0

	log_info "Summary:"
	local item
	for item in "${SUMMARY_LINES[@]}"; do
		log_info "  - ${item}"
	done
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

assignment_file_value() {
	local file="$1"
	local name="$2"
	[ -f "$file" ] || return 1

	awk -F= -v key="$name" '
		{
			line = $0
			sub(/^[[:space:]]*export[[:space:]]+/, "", line)
			split(line, parts, "=")
			if (parts[1] == key) {
				sub(/^[^=]*=/, "", line)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
				if ((line ~ /^".*"$/) || (line ~ /^'\''.*'\''$/)) {
					line = substr(line, 2, length(line) - 2)
				}
				print line
				exit
			}
		}
	' "$file"
}

resolved_network_override_supplied() {
	local name="$1"
	local default_value="$2"
	local file value

	if runtime_env_has "$name"; then
		return 0
	fi

	for file in "$CONFIG_FILE" "$ENV_FILE"; do
		value="$(assignment_file_value "$file" "$name" || true)"
		[ -n "$value" ] || continue
		if [ "$value" != "$default_value" ]; then
			return 0
		fi
	done

	return 1
}

runtime_env_has() {
	local name="$1"
	case "
${ORIGINAL_ENV_KEYS}
" in
	*"
${name}
"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

load_assignment_file() {
	local file="$1"
	[ -f "$file" ] || return 0

	local tmp_file line var
	tmp_file="$(mktemp)"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		esac
		var="${line%%=*}"
		var="${var#export }"
		if [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && ! runtime_env_has "$var"; then
			printf '%s\n' "$line" >>"$tmp_file"
		fi
	done <"$file"

	if [ -s "$tmp_file" ]; then
		# shellcheck disable=SC1090
		. "$tmp_file"
	fi
	rm -f "$tmp_file"
}

is_enabled() {
	case "${1:-}" in
	[yY] | [yY][eE][sS] | [tT][rR][uU][eE] | 1 | [oO][nN])
		return 0
		;;
	*)
		return 1
		;;
	esac
}

normalize_bool() {
	if is_enabled "${1:-}"; then
		echo "yes"
	else
		echo "no"
	fi
}

reachable_host() {
	local host="$1"
	[ -n "$host" ] || return 1
	host="${host%:*}"
	ping -c 1 -W 1 "$host" >/dev/null 2>&1
}

resolve_ipv4_host() {
	local host="$1"
	host="${host%:*}"
	[ -n "$host" ] || return 1
	if valid_ipv4 "$host"; then
		echo "$host"
		return 0
	fi
	getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

ip_to_int() {
	local IFS=.
	local a b c d
	read -r a b c d <<-EOF
	$1
	EOF
	echo $(((a << 24) + (b << 16) + (c << 8) + d))
}

int_to_ip() {
	local ip="$1"
	printf '%d.%d.%d.%d\n' "$(((ip >> 24) & 255))" "$(((ip >> 16) & 255))" "$(((ip >> 8) & 255))" "$((ip & 255))"
}

valid_ipv4() {
	local ip="$1"
	local IFS=.
	local a b c d
	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	read -r a b c d <<-EOF
	$ip
	EOF
	[ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

prefix_mask_int() {
	local prefix="$1"
	if [ "$prefix" -eq 0 ]; then
		echo 0
	else
		echo $((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
	fi
}

cidr_network_int() {
	local cidr="$1"
	local ip="${cidr%/*}"
	local prefix="${cidr#*/}"
	echo $(($(ip_to_int "$ip") & $(prefix_mask_int "$prefix")))
}

cidr_broadcast_int() {
	local cidr="$1"
	local prefix="${cidr#*/}"
	local network mask
	network="$(cidr_network_int "$cidr")"
	mask="$(prefix_mask_int "$prefix")"
	echo $((network | (0xFFFFFFFF ^ mask)))
}

cidr_overlaps() {
	local a="$1"
	local b="$2"
	local a_net a_brd b_net b_brd
	a_net="$(cidr_network_int "$a")"
	a_brd="$(cidr_broadcast_int "$a")"
	b_net="$(cidr_network_int "$b")"
	b_brd="$(cidr_broadcast_int "$b")"
	[ "$a_net" -le "$b_brd" ] && [ "$b_net" -le "$a_brd" ]
}

netmask_from_prefix() {
	prefix_mask_int "$1" | while read -r mask; do int_to_ip "$mask"; done
}

reverse_zone_name() {
	local cidr="$1"
	local network="${cidr%/*}"
	local prefix="${cidr#*/}"
	local IFS=.
	local a b c d zone_octets
	read -r a b c d <<-EOF
	$network
	EOF
	zone_octets=$((prefix / 8))
	if [ "$zone_octets" -lt 1 ]; then
		zone_octets=1
	elif [ "$zone_octets" -gt 3 ]; then
		zone_octets=3
	fi
	case "$zone_octets" in
	1)
		printf '%s.in-addr.arpa' "$a"
		;;
	2)
		printf '%s.%s.in-addr.arpa' "$b" "$a"
		;;
	*)
		printf '%s.%s.%s.in-addr.arpa' "$c" "$b" "$a"
		;;
	esac
}

reverse_ptr_owner() {
	local ip="$1"
	local cidr="$2"
	local prefix="${cidr#*/}"
	local IFS=.
	local a b c d zone_octets
	read -r a b c d <<-EOF
	$ip
	EOF
	zone_octets=$((prefix / 8))
	if [ "$zone_octets" -lt 1 ]; then
		zone_octets=1
	elif [ "$zone_octets" -gt 3 ]; then
		zone_octets=3
	fi
	case "$zone_octets" in
	1)
		printf '%s.%s.%s' "$d" "$c" "$b"
		;;
	2)
		printf '%s.%s' "$d" "$c"
		;;
	*)
		printf '%s' "$d"
		;;
	esac
}

kernel_version_from_package() {
	local pkg="$1"
	pkg="${pkg#proxmox-kernel-}"
	pkg="${pkg#pve-kernel-}"
	pkg="${pkg%-signed}"
	echo "$pkg"
}

list_installed_pve_kernel_packages() {
	dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(proxmox|pve)-kernel-[0-9].*-pve(-signed)?$' || true
}

configure_nested_virtualization() {
	if ! is_enabled "$ENABLE_NESTED_VIRT"; then
		return 0
	fi

	local module nested_value nested_param current_value
	module=""
	nested_value=""
	if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
		module="kvm_amd"
		nested_value="1"
	elif grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
		module="kvm_intel"
		nested_value="Y"
	else
		return 0
	fi

	mkdir -p /etc/modprobe.d
	backup_file /etc/modprobe.d/proxmox-bootstrap-kvm.conf
	printf 'options %s nested=%s\n' "$module" "$nested_value" >/etc/modprobe.d/proxmox-bootstrap-kvm.conf

	modprobe "$module" >/dev/null 2>&1 || true
	nested_param="/sys/module/${module}/parameters/nested"
	if [ -w "$nested_param" ]; then
		current_value="$(cat "$nested_param" 2>/dev/null || true)"
		if [ "$current_value" != "$nested_value" ]; then
			printf '%s' "$nested_value" >"$nested_param" 2>/dev/null || true
		fi
	fi

	current_value="$(cat "$nested_param" 2>/dev/null || true)"
	case "$current_value" in
	1 | Y | y)
		add_summary "Enabled nested virtualization for ${module}"
		;;
	*)
		log_warn "Nested virtualization for ${module} is configured but may require a reboot or module reload"
		;;
	esac
}

postfix_relay_explicitly_configured() {
	local name value
	for name in POSTFIX_SMTP_RELAY MAIL_RELAY_HOST SMTP_RELAY; do
		if runtime_env_has "$name"; then
			value="${!name:-}"
			[ "$value" = "mail.example.com" ] && continue
			return 0
		fi
		value="$(assignment_file_value "$CONFIG_FILE" "$name" || true)"
		if [ -n "$value" ] && [ "$value" != "mail.example.com" ]; then
			return 0
		fi
		value="$(assignment_file_value "$ENV_FILE" "$name" || true)"
		if [ -n "$value" ] && [ "$value" != "mail.example.com" ]; then
			return 0
		fi
	done
	return 1
}

split_csv_ports() {
	echo "${1:-}" | tr ',' ' ' | awk 'NF'
}

comma_list_ports() {
	echo "${1:-}" | sed 's/[[:space:]]//g' | sed 's/,/, /g'
}

load_resolved_network_state() {
	[ -f "$RESOLVED_NETWORK_STATE_FILE" ] || return 0

	local persisted_lan_br persisted_lan_nic persisted_router_br persisted_router_nic
	persisted_lan_br="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "LAN_BR" || true)"
	persisted_lan_nic="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "LAN_NIC" || true)"
	persisted_router_br="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "ROUTER_BR" || true)"
	persisted_router_nic="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "ROUTER_NIC" || true)"

	if [ -n "$persisted_lan_br" ]; then
		if resolved_network_override_supplied "LAN_BR" "vmbr1"; then
			if [ "$LAN_BR" != "$persisted_lan_br" ]; then
				log_info "Explicit LAN_BR overrides persisted state (${persisted_lan_br} -> ${LAN_BR})"
			fi
		else
			LAN_BR="$persisted_lan_br"
		fi
	fi

	if [ -n "$persisted_lan_nic" ]; then
		if resolved_network_override_supplied "LAN_NIC" ""; then
			if [ "$LAN_NIC" != "$persisted_lan_nic" ]; then
				log_info "Explicit LAN_NIC overrides persisted state (${persisted_lan_nic} -> ${LAN_NIC})"
			fi
		else
			LAN_NIC="$persisted_lan_nic"
		fi
	fi

	if [ -n "$persisted_router_br" ]; then
		if resolved_network_override_supplied "ROUTER_BR" ""; then
			if [ "$ROUTER_BR" != "$persisted_router_br" ]; then
				log_info "Explicit ROUTER_BR overrides persisted state (${persisted_router_br} -> ${ROUTER_BR})"
			fi
		else
			ROUTER_BR="$persisted_router_br"
		fi
	fi

	if [ -n "$persisted_router_nic" ]; then
		if resolved_network_override_supplied "ROUTER_NIC" ""; then
			if [ "$ROUTER_NIC" != "$persisted_router_nic" ]; then
				log_info "Explicit ROUTER_NIC overrides persisted state (${persisted_router_nic} -> ${ROUTER_NIC})"
			fi
		else
			ROUTER_NIC="$persisted_router_nic"
		fi
	fi
}

persist_resolved_network_state() {
	local tmp_file old_lan_br old_lan_nic old_router_br old_router_nic
	old_lan_br="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "LAN_BR" || true)"
	old_lan_nic="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "LAN_NIC" || true)"
	old_router_br="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "ROUTER_BR" || true)"
	old_router_nic="$(assignment_file_value "$RESOLVED_NETWORK_STATE_FILE" "ROUTER_NIC" || true)"

	mkdir -p "$(dirname "$RESOLVED_NETWORK_STATE_FILE")"
	tmp_file="$(mktemp)"
	cat >"$tmp_file" <<-EOF
		LAN_BR="${LAN_BR}"
		LAN_NIC="${LAN_NIC}"
		ROUTER_BR="${ROUTER_BR}"
		ROUTER_NIC="${ROUTER_NIC}"
	EOF
	mv "$tmp_file" "$RESOLVED_NETWORK_STATE_FILE"
	chmod 600 "$RESOLVED_NETWORK_STATE_FILE"

	if [ "$old_lan_br" != "$LAN_BR" ] || [ "$old_lan_nic" != "$LAN_NIC" ] || [ "$old_router_br" != "$ROUTER_BR" ] || [ "$old_router_nic" != "$ROUTER_NIC" ]; then
		log_info "Persisted resolved network state: lan_bridge=${LAN_BR}, lan_nic=${LAN_NIC}, router_bridge=${ROUTER_BR}, router_nic=${ROUTER_NIC}"
	fi
}

detect_lan_domain() {
	local domain short
	domain="$(hostname -d 2>/dev/null || true)"
	if [ -n "$domain" ] && [ "$domain" != "(none)" ]; then
		echo "$domain"
		return
	fi
	short="$(hostname -s 2>/dev/null || true)"
	if [ -n "$short" ] && [ "$short" != "(none)" ]; then
		echo "${short}.home"
		return
	fi
	echo "pve.home"
}

derive_config_values() {
	if [ -z "$LAN_DOMAIN" ]; then
		LAN_DOMAIN="$(detect_lan_domain)"
	fi

	if [ -z "$LAN_V4_IP" ]; then
		LAN_V4_IP="${LAN_V4%%/*}"
	fi

	if [ -z "$WAN_V4_IP" ] && [ -n "$WAN_V4" ]; then
		WAN_V4_IP="${WAN_V4%%/*}"
	fi

	if [ -z "$WAN_V4_IP" ] && ip link show "$WAN_BR" >/dev/null 2>&1; then
		WAN_V4_IP=$(ip -4 addr show "$WAN_BR" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
	fi

	MAIL_RELAY_HOST="${MAIL_RELAY_HOST:-$SMTP_RELAY}"
	MAIL_RELAY_PORT="${MAIL_RELAY_PORT:-$SMTP_PORT}"
	ROOT_MAIL_FORWARD="${ROOT_MAIL_FORWARD:-$ROOT_EMAIL}"
	SMTP_RELAY="$MAIL_RELAY_HOST"
	SMTP_PORT="$MAIL_RELAY_PORT"
	ROOT_EMAIL="$ROOT_MAIL_FORWARD"

	POSTFIX_SMTP_RELAY="${POSTFIX_SMTP_RELAY:-$MAIL_RELAY_HOST}"
	POSTFIX_SMTP_PORT="${POSTFIX_SMTP_PORT:-$MAIL_RELAY_PORT}"
	POSTFIX_ROOT_FORWARD="${POSTFIX_ROOT_FORWARD:-$ROOT_MAIL_FORWARD}"
	POSTFIX_MYDOMAIN="${POSTFIX_MYDOMAIN:-$LAN_DOMAIN}"

	if [ -z "$POSTFIX_MYHOSTNAME" ]; then
		POSTFIX_MYHOSTNAME="$(hostname -f 2>/dev/null || hostname)"
	fi

	normalize_postfix_type
	normalize_service_modes
	derive_lan_network_values
	validate_dhcp_v4_range
	GUEST_DEFAULT_BRIDGE="${GUEST_DEFAULT_BRIDGE:-$LAN_BR}"
	DHCP_RELAY_INTERFACES="${DHCP_RELAY_INTERFACES:-$LAN_BR}"
}

normalize_postfix_type() {
	if [ "$POSTFIX_SERVER_TYPE" = "local" ] && postfix_relay_explicitly_configured && [ -n "$POSTFIX_SMTP_RELAY" ]; then
		POSTFIX_SERVER_TYPE="relay"
		log_info "Detected explicit relay host; using POSTFIX_SERVER_TYPE=relay"
	fi

	case "$POSTFIX_SERVER_TYPE" in
	local | relay | satellite | internet | forward)
		;;
	*)
		if [ -n "$POSTFIX_SMTP_RELAY" ]; then
			log_warn "Invalid POSTFIX_SERVER_TYPE '$POSTFIX_SERVER_TYPE'; falling back to relay"
			POSTFIX_SERVER_TYPE="relay"
		else
			log_warn "Invalid POSTFIX_SERVER_TYPE '$POSTFIX_SERVER_TYPE'; falling back to local"
			POSTFIX_SERVER_TYPE="local"
		fi
		;;
	esac

	if [ -z "$POSTFIX_RELAY_TLS" ]; then
		if [ "$POSTFIX_SMTP_PORT" = "587" ]; then
			POSTFIX_RELAY_TLS="yes"
		else
			POSTFIX_RELAY_TLS="no"
		fi
	fi
}

normalize_service_modes() {
	case "$DNS_SERVER_TYPE" in
	local | forward | disabled) ;;
	*)
		log_warn "Invalid DNS_SERVER_TYPE '$DNS_SERVER_TYPE'; falling back to local"
		DNS_SERVER_TYPE="local"
		;;
	esac

	if [ "$DNS_SERVER_TYPE" = "forward" ] && ! reachable_host "$DNS_FORWARD_HOST"; then
		log_warn "DNS forward host unavailable; falling back to local DNS"
		DNS_SERVER_TYPE="local"
	fi

	case "$DHCP_SERVER_TYPE" in
	local | relay | disabled) ;;
	*)
		log_warn "Invalid DHCP_SERVER_TYPE '$DHCP_SERVER_TYPE'; falling back to local"
		DHCP_SERVER_TYPE="local"
		;;
	esac

	if [ "$DHCP_SERVER_TYPE" = "relay" ] && ! reachable_host "$DHCP_RELAY_HOST"; then
		log_warn "DHCP relay host unavailable; falling back to local DHCP"
		DHCP_SERVER_TYPE="local"
	fi

	case "$RA_SERVER_TYPE" in
	local | disabled) ;;
	*)
		log_warn "Invalid RA_SERVER_TYPE '$RA_SERVER_TYPE'; falling back to local"
		RA_SERVER_TYPE="local"
		;;
	esac

	if [ "$RA_SERVER_TYPE" = "disabled" ] && [ "$LAN_V6_STATEFUL" != "no" ] && [ "$DHCP_SERVER_TYPE" = "local" ]; then
		log_warn "RA is disabled; disabling local stateful DHCPv6 to avoid inconsistent IPv6 advertisements"
		LAN_V6_STATEFUL="no"
	fi
}

derive_lan_network_values() {
	local ip prefix network brd third
	ip="${LAN_V4%%/*}"
	prefix="${LAN_V4#*/}"
	network="$(int_to_ip "$(cidr_network_int "$LAN_V4")")"
	brd="$(int_to_ip "$(cidr_broadcast_int "$LAN_V4")")"

	LAN_V4_IP="${LAN_V4_IP:-$ip}"
	LAN_V4_NET="${LAN_V4_NET:-${network}/${prefix}}"
	LAN_V4_BRD="${LAN_V4_BRD:-$brd}"

	if [ -z "$DHCP_V4_START" ] || [ -z "$DHCP_V4_END" ]; then
		local IFS=.
		local a b c d
		read -r a b c d <<-EOF
		$network
		EOF
		if [ "$prefix" -eq 24 ]; then
			DHCP_V4_START="${a}.${b}.${c}.100"
			DHCP_V4_END="${a}.${b}.${c}.200"
		elif [ "$prefix" -le 16 ]; then
			DHCP_V4_START="${a}.${b}.1.10"
			DHCP_V4_END="${a}.${b}.255.254"
		else
			DHCP_V4_START="$(int_to_ip "$(( $(cidr_network_int "$LAN_V4") + 10 ))")"
			DHCP_V4_END="$(int_to_ip "$(( $(cidr_broadcast_int "$LAN_V4") - 1 ))")"
		fi
	fi

	third="$(echo "$LAN_V4_IP" | cut -d. -f3)"
	LAN_V6_PREFIX="${LAN_V6_PREFIX:-fd00:${third}::/64}"
	LAN_V6_ROUTER_IP="${LAN_V6_ROUTER_IP:-fd00:${third}::1}"
	LAN_V6_RANGE_LOW="${LAN_V6_RANGE_LOW:-fd00:${third}::200}"
	LAN_V6_RANGE_HIGH="${LAN_V6_RANGE_HIGH:-fd00:${third}::3ff}"
}

validate_dhcp_v4_range() {
	local start end network broadcast prefix
	start="${DHCP_V4_START:-}"
	end="${DHCP_V4_END:-}"
	[ -n "$start" ] || return 0
	[ -n "$end" ] || return 0

	valid_ipv4 "$start" || log_fatal "Invalid DHCP_V4_START IPv4 address: $start"
	valid_ipv4 "$end" || log_fatal "Invalid DHCP_V4_END IPv4 address: $end"

	network="$(cidr_network_int "$LAN_V4")"
	broadcast="$(cidr_broadcast_int "$LAN_V4")"
	prefix="${LAN_V4#*/}"
	start="$(ip_to_int "$start")"
	end="$(ip_to_int "$end")"

	if [ "$start" -gt "$end" ]; then
		log_fatal "DHCP_V4_START must be less than or equal to DHCP_V4_END"
	fi

	if [ "$start" -lt "$network" ] || [ "$end" -gt "$broadcast" ]; then
		log_fatal "DHCP override range must stay inside selected LAN subnet: ${LAN_V4}"
	fi

	if [ "$prefix" -lt 31 ] && { [ "$start" -le "$network" ] || [ "$end" -ge "$broadcast" ]; }; then
		log_fatal "DHCP override range must not include the LAN network or broadcast address"
	fi
}

backup_file() {
	local file="$1"
	if [ -f "$file" ]; then
		local backup_path="${BACKUP_DIR}${file}"
		mkdir -p "$(dirname "$backup_path")"
		cp -a "$file" "$backup_path"
		log_info "Backed up: $file"
	fi
}

check_root() {
	if [ "$(id -u)" -ne 0 ]; then
		log_fatal "This script must be run as root"
	fi
	export DEBIAN_FRONTEND=noninteractive
	mkdir -p /var/tmp
}

warn_if_backup_parent_unmounted() {
	local backup_parent
	backup_parent="$(dirname "$BACKUP_BASE_DIR")"
	[ -d "$backup_parent" ] || return 0
	if ! mountpoint -q "$backup_parent" 2>/dev/null; then
		log_warn "Backup parent path ${backup_parent} is not a separate mount point; backups will be stored on the root filesystem unless you override BACKUP_BASE_DIR"
	fi
}

get_host_fqdn() {
	local fqdn
	fqdn="$(hostname -f 2>/dev/null || true)"
	if [ -n "$fqdn" ] && printf '%s' "$fqdn" | grep -q '\.'; then
		echo "$fqdn"
		return 0
	fi
	if [ -n "${PVE_NODE_NAME:-}" ] && [ -n "${LAN_DOMAIN:-}" ]; then
		echo "${PVE_NODE_NAME}.${LAN_DOMAIN}"
		return 0
	fi
	echo "$(get_pve_node_name).${LAN_DOMAIN}"
}

configure_letsencrypt_pve_cert_hook() {
	local fqdn hook_dir hook_file le_dir
	fqdn="$(get_host_fqdn)"
	hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
	hook_file="${hook_dir}/proxmox-bootstrap-copy-pve-cert"
	le_dir=""

	if [ -d /etc/letsencrypt/live/domain ]; then
		le_dir="/etc/letsencrypt/live/domain"
	elif [ -d "/etc/letsencrypt/live/${fqdn}" ]; then
		le_dir="/etc/letsencrypt/live/${fqdn}"
	fi

	mkdir -p "$hook_dir"
	backup_file "$hook_file"
	cat >"$hook_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

	lineage="${RENEWED_LINEAGE:-}"
	if [ -z "$lineage" ]; then
		for candidate in "/etc/letsencrypt/live/domain" "/etc/letsencrypt/live/$(hostname -f 2>/dev/null || hostname)"; do
			[ -d "$candidate" ] || continue
			lineage="$candidate"
			break
		done
	fi

	[ -n "$lineage" ] || exit 0
	[ -f "${lineage}/fullchain.pem" ] || exit 0
	[ -f "${lineage}/privkey.pem" ] || exit 0

	cert_tmp="$(mktemp)"
	key_tmp="$(mktemp)"
	trap 'rm -f "$cert_tmp" "$key_tmp"' EXIT

	cat "${lineage}/fullchain.pem" >"$cert_tmp"
	cat "${lineage}/privkey.pem" >"$key_tmp"
	cat "$cert_tmp" >/etc/pve/local/pve-ssl.pem
	cat "$key_tmp" >/etc/pve/local/pve-ssl.key

	systemctl reload-or-restart pveproxy >/dev/null 2>&1 || systemctl restart pveproxy >/dev/null 2>&1 || true
	if systemctl is-active --quiet nginx; then
		systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
	fi
EOF
	chmod 750 "$hook_file"

	if [ -n "$le_dir" ] && [ -f "${le_dir}/fullchain.pem" ] && [ -f "${le_dir}/privkey.pem" ]; then
		"$hook_file" || log_fatal "Failed to copy Let's Encrypt certificates from ${le_dir}"
		add_summary "Synced Let's Encrypt certificates from ${le_dir} into Proxmox"
	fi
}

run_apt_noninteractive() {
	local attempt rc log_file policy_rc backup_policy_rc restore_backup=0
	log_file="$(mktemp)"
	policy_rc="/usr/sbin/policy-rc.d"
	backup_policy_rc="$(mktemp)"

	if [ -e "$policy_rc" ]; then
		cp -a "$policy_rc" "$backup_policy_rc"
		restore_backup=1
	fi

	cat >"$policy_rc" <<-'EOF'
		#!/bin/sh
		exit 101
	EOF
	chmod 755 "$policy_rc"

	for attempt in 1 2 3; do
		if TMPDIR=/var/tmp DEBIAN_FRONTEND=noninteractive "$@" >"$log_file" 2>&1; then
			if [ "$restore_backup" -eq 1 ]; then
				mv "$backup_policy_rc" "$policy_rc"
			else
				rm -f "$policy_rc" "$backup_policy_rc"
			fi
			rm -f "$log_file"
			return 0
		fi

		rc=$?
		if grep -qE "cannot stat pathname '.*/apt-dpkg-install-" "$log_file"; then
			log_warn "apt/dpkg temporary file race detected; retrying (${attempt}/3)"
			TMPDIR=/var/tmp DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
			TMPDIR=/var/tmp DEBIAN_FRONTEND=noninteractive apt-get -f install -y \
				-o Dpkg::Options::="--force-confdef" \
				-o Dpkg::Options::="--force-confold" >/dev/null 2>&1 || true
			apt-get clean >/dev/null 2>&1 || true
			continue
		fi

		break
	done

	cat "$log_file" >>"$LOG_FILE"
	if [ "$restore_backup" -eq 1 ]; then
		mv "$backup_policy_rc" "$policy_rc"
	else
		rm -f "$policy_rc" "$backup_policy_rc"
	fi
	rm -f "$log_file"
	return "${rc:-1}"
}

unmask_service_if_needed() {
	local service="$1"
	if [ "$(systemctl is-enabled "$service" 2>/dev/null || true)" = "masked" ]; then
		systemctl unmask "$service" >/dev/null 2>&1 || log_warn "Could not unmask ${service}"
	fi
}

reload_network_config() {
	local attempt rc output

	if command_exists ifreload; then
		for attempt in 1 2 3; do
			output="$(ifreload -a 2>&1)"
			rc=$?
			[ -z "$output" ] || printf '%s\n' "$output" >>"$LOG_FILE"
			if [ "$rc" -eq 0 ]; then
				return 0
			fi
			if printf '%s\n' "$output" | grep -q "Another instance of this program is already running"; then
				log_warn "ifreload busy; retrying (${attempt}/3)"
				sleep 2
				continue
			fi
			return "$rc"
		done
		return 1
	fi

	systemctl restart networking >/dev/null 2>&1
}

configure_apparmor() {
	log_info "Configuring AppArmor..."

	if ! command_exists aa-status; then
		log_info "AppArmor tools not installed yet, skipping profile reload"
		return 0
	fi

	unmask_service_if_needed apparmor
	systemctl enable apparmor >/dev/null 2>&1 || true
	systemctl start apparmor >/dev/null 2>&1 || true

	for profile in /etc/apparmor.d/usr.sbin.named /etc/apparmor.d/usr.sbin.dhcpd /etc/apparmor.d/usr.sbin.radvd /etc/apparmor.d/usr.sbin.postfix; do
		[ -f "$profile" ] || continue
		apparmor_parser -r "$profile" >/dev/null 2>&1 || log_warn "Could not reload AppArmor profile: $profile"
	done

	log_success "AppArmor configured"
}

detect_pve_version() {
	if ! command_exists pveversion; then
		log_fatal "Proxmox VE not detected. This script requires Proxmox VE 7+"
	fi

	local pve_version
	pve_version=$(pveversion | head -n1 | cut -d'/' -f2 | cut -d'.' -f1)
	PVE_MAJOR_VERSION="$pve_version"

	if [ "$PVE_MAJOR_VERSION" -lt 7 ]; then
		log_fatal "Unsupported Proxmox VE version: $PVE_MAJOR_VERSION (requires 7+)"
	fi

	log_info "Detected Proxmox VE version: $PVE_MAJOR_VERSION"
}

get_pve_node_name() {
	if [ -d /etc/pve/nodes ]; then
		find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n1
	else
		hostname -s 2>/dev/null || hostname
	fi
}

configure_node_name() {
	[ -n "$PVE_NODE_NAME" ] || return 0

	local current_node
	current_node="$(get_pve_node_name)"
	if [ -z "$current_node" ] || [ "$current_node" = "$PVE_NODE_NAME" ]; then
		return 0
	fi

	if command_exists pvecm && pvecm status >/dev/null 2>&1 && ! is_enabled "$FORCE_NODE_RENAME"; then
		log_fatal "Refusing to rename clustered Proxmox node without FORCE_NODE_RENAME=yes"
	fi

	log_warn "Renaming Proxmox node from ${current_node} to ${PVE_NODE_NAME}"
	backup_file /etc/hostname
	backup_file /etc/hosts
	backup_file /etc/mailname

	echo "$PVE_NODE_NAME" >/etc/hostname
	hostname "$PVE_NODE_NAME" 2>/dev/null || true

	if [ -f /etc/hosts ]; then
		sed -i "s/\b${current_node}\b/${PVE_NODE_NAME}/g" /etc/hosts
	fi
	if [ -f /etc/mailname ]; then
		sed -i "s/\b${current_node}\b/${PVE_NODE_NAME}/g" /etc/mailname
	fi

	if [ -d "/etc/pve/nodes/${current_node}" ] && [ ! -e "/etc/pve/nodes/${PVE_NODE_NAME}" ]; then
		mv "/etc/pve/nodes/${current_node}" "/etc/pve/nodes/${PVE_NODE_NAME}" || log_warn "Could not move /etc/pve/nodes/${current_node}"
	fi

	POSTFIX_MYHOSTNAME="${PVE_NODE_NAME}.${LAN_DOMAIN}"
	log_success "Node rename applied; reboot may be required for all Proxmox services"
}

get_debian_codename() {
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		echo "${VERSION_CODENAME:-}"
	fi
}

detect_network_interfaces() {
	log_info "Detecting network interfaces..."

	local interfaces
	interfaces=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$' | grep -Ev '^(vmbr|veth|tap|docker|pvedummy|pverouter)' || true)

	local nic_count
	nic_count=$(printf '%s\n' "$interfaces" | sed '/^$/d' | wc -l)

	if [ -z "$WAN_NIC" ] && ip link show "$WAN_BR" >/dev/null 2>&1; then
		WAN_NIC="$(bridge_ports_for "$WAN_BR" | awk '{print $1}')"
	fi

	if [ -z "$WAN_NIC" ]; then
		WAN_NIC=$(printf '%s\n' "$interfaces" | sed '/^$/d' | head -n1)
	fi

	local existing_lan
	existing_lan="$(existing_lan_bridge)"
	if [ -n "$existing_lan" ] && [ -z "$LAN_NIC" ]; then
		LAN_BR="$existing_lan"
		LAN_NIC="$(bridge_ports_for "$LAN_BR" | awk '{print $1}')"
	fi

	if [ "$nic_count" -eq 1 ]; then
		SINGLE_NIC_MODE=true
		LAN_NIC="${LAN_NIC:-$(next_free_dummy)}"
		LAN_BR="$(resolve_lan_bridge)"
		log_info "Single NIC detected, will use dummy interface for LAN"
	elif [ "$nic_count" -eq 2 ]; then
		SINGLE_NIC_MODE=false
		if [ -z "$LAN_NIC" ]; then
			LAN_NIC=$(printf '%s\n' "$interfaces" | sed '/^$/d' | awk -v wan="$WAN_NIC" '$0 != wan { print; exit }')
		fi
		LAN_BR="$(resolve_lan_bridge)"
		log_info "Dual NIC detected"
	elif [ "$nic_count" -gt 2 ]; then
		SINGLE_NIC_MODE=false
		if [ -z "$LAN_NIC" ]; then
			LAN_NIC="$(next_free_dummy)"
		fi
		LAN_BR="$(resolve_lan_bridge)"
		log_info "More than two NICs detected, preserving physical NICs and using dummy interface for LAN"
	else
		log_fatal "No network interfaces detected"
	fi

	resolve_router_lab_network

	log_info "  WAN NIC: ${WAN_NIC}"
	log_info "  LAN NIC: ${LAN_NIC}"
	[ -n "$ROUTER_NIC" ] && log_info "  Router NIC: ${ROUTER_NIC}"
	[ -n "$ROUTER_BR" ] && log_info "  Router bridge: ${ROUTER_BR}"
	log_info "  Single NIC mode: ${SINGLE_NIC_MODE}"
	persist_resolved_network_state
}

bridge_ports_for() {
	local bridge="$1"
	awk -v br="$bridge" '
		$1 == "iface" && $2 == br { in_stanza = 1; next }
		$1 == "auto" || $1 == "iface" { if (in_stanza) exit }
		in_stanza && $1 == "bridge-ports" {
			for (i = 2; i <= NF; i++) print $i
		}
	' /etc/network/interfaces 2>/dev/null || true
}

next_free_bridge() {
	local idx=1
	while ip link show "vmbr${idx}" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+vmbr${idx}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; do
		idx=$((idx + 1))
	done
	echo "vmbr${idx}"
}

next_free_dummy() {
	local idx=0
	while ip link show "pvedummy${idx}" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+pvedummy${idx}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; do
		idx=$((idx + 1))
	done
	echo "pvedummy${idx}"
}

next_free_router_dummy() {
	local idx=0
	while ip link show "pverouter${idx}" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+pverouter${idx}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; do
		idx=$((idx + 1))
	done
	echo "pverouter${idx}"
}

is_dummy_lan_iface() {
	local iface="${1:-$LAN_NIC}"
	echo "$iface" | grep -Eq '^pvedummy[0-9]+$'
}

is_router_dummy_iface() {
	local iface="${1:-$ROUTER_NIC}"
	echo "$iface" | grep -Eq '^pverouter[0-9]+$'
}

resolve_lan_bridge() {
	if ip link show "$LAN_BR" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+${LAN_BR}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; then
		local ports
		ports="$(bridge_ports_for "$LAN_BR" | tr '\n' ' ')"
		if [ -n "$ports" ] && ! echo "$ports" | grep -qw "$LAN_NIC"; then
			next_free_bridge
			return
		fi
	fi
	echo "$LAN_BR"
}

next_free_bridge_from() {
	local idx="$1"
	while ip link show "vmbr${idx}" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+vmbr${idx}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; do
		idx=$((idx + 1))
	done
	echo "vmbr${idx}"
}

router_bridge_uses_target_port() {
	local ports
	[ -n "$ROUTER_BR" ] || return 0
	[ -n "$ROUTER_NIC" ] || return 1
	ports="$(bridge_ports_for "$ROUTER_BR" | tr '\n' ' ')"
	[ -n "$ports" ] || return 1
	echo "$ports" | grep -qw "$ROUTER_NIC"
}

router_bridge_vlan_aware_configured() {
	[ -n "$ROUTER_BR" ] || return 0
	awk -v bridge="$ROUTER_BR" '
		$1 == "iface" && $2 == bridge && $4 == "manual" { in_stanza = 1; next }
		in_stanza && $1 == "bridge-vlan-aware" && $2 == "yes" { found = 1; exit 0 }
		in_stanza && ($1 == "iface" || $1 == "auto" || $1 == "source") { exit(found ? 0 : 1) }
		END { exit(found ? 0 : 1) }
	' /etc/network/interfaces 2>/dev/null
}

resolve_router_lab_network() {
	local lan_dummy_idx lan_bridge_idx preferred_router_idx preferred_bridge_idx ports

	case "$LAN_NIC" in
	pvedummy[0-9]*)
		lan_dummy_idx="${LAN_NIC#pvedummy}"
		;;
	*)
		ROUTER_NIC=""
		ROUTER_BR=""
		return 0
		;;
	esac

	case "$LAN_BR" in
	vmbr[0-9]*)
		lan_bridge_idx="${LAN_BR#vmbr}"
		;;
	*)
		lan_bridge_idx=""
		;;
	esac

	if [ -z "$ROUTER_NIC" ]; then
		preferred_router_idx=$((lan_dummy_idx + 1))
		if ip link show "pverouter${preferred_router_idx}" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+pverouter${preferred_router_idx}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; then
			ROUTER_NIC="$(next_free_router_dummy)"
		else
			ROUTER_NIC="pverouter${preferred_router_idx}"
		fi
	fi

	if [ -z "$ROUTER_BR" ]; then
		if [ -n "$lan_bridge_idx" ]; then
			preferred_bridge_idx=$((lan_bridge_idx + 1))
			ROUTER_BR="$(next_free_bridge_from "$preferred_bridge_idx")"
		else
			ROUTER_BR="$(next_free_bridge)"
		fi
	fi

	if ip link show "$ROUTER_BR" >/dev/null 2>&1 || grep -qE "^(auto|iface)[[:space:]]+${ROUTER_BR}([[:space:]]|$)" /etc/network/interfaces 2>/dev/null; then
		ports="$(bridge_ports_for "$ROUTER_BR" | tr '\n' ' ')"
		if [ -n "$ports" ] && ! echo "$ports" | grep -qw "$ROUTER_NIC"; then
			if [ -n "$lan_bridge_idx" ]; then
				preferred_bridge_idx=$((lan_bridge_idx + 1))
				ROUTER_BR="$(next_free_bridge_from "$preferred_bridge_idx")"
			else
				ROUTER_BR="$(next_free_bridge)"
			fi
		fi
	fi
}

ensure_lan_bridge_settings() {
	local tmp_file
	tmp_file="$(mktemp)"

	awk -v bridge="$LAN_BR" -v nic="$LAN_NIC" '
		function emit_target(    i, line, saw_vlan) {
			saw_vlan = 0
			for (i = 1; i <= count; i++) {
				line = buf[i]
				if (line ~ /^[[:space:]]*bridge-ports[[:space:]]+/) {
					print "    bridge-ports " nic
					continue
				}
				if (line ~ /^[[:space:]]*bridge-vlan-aware[[:space:]]+/) {
					print "    bridge-vlan-aware yes"
					saw_vlan = 1
					continue
				}
				print line
				if (!saw_vlan && line ~ /^[[:space:]]*bridge-fd[[:space:]]+/) {
					print "    bridge-vlan-aware yes"
					saw_vlan = 1
				}
			}
		}

		function flush_target() {
			if (!capturing) {
				return
			}
			emit_target()
			delete buf
			count = 0
			capturing = 0
		}

		{
			if (capturing) {
				if ($0 == "") {
					flush_target()
					print ""
					next
				}
				if ($0 ~ /^(auto|iface|source)[[:space:]]+/) {
					flush_target()
				} else {
					buf[++count] = $0
					next
				}
			}

			if ($0 == "iface " bridge " inet static") {
				capturing = 1
				buf[++count] = $0
				next
			}

			print
		}

		END {
			flush_target()
		}
	' /etc/network/interfaces >"$tmp_file"

	mv "$tmp_file" /etc/network/interfaces
	chmod 644 /etc/network/interfaces
}

ensure_router_bridge_settings() {
	local tmp_file

	[ -n "$ROUTER_BR" ] || return 0
	[ -n "$ROUTER_NIC" ] || return 0

	tmp_file="$(mktemp)"

	awk -v bridge="$ROUTER_BR" -v nic="$ROUTER_NIC" '
		function emit_target(    i, line, saw_vlan) {
			saw_vlan = 0
			for (i = 1; i <= count; i++) {
				line = buf[i]
				if (line ~ /^[[:space:]]*bridge-ports[[:space:]]+/) {
					print "    bridge-ports " nic
					continue
				}
				if (line ~ /^[[:space:]]*bridge-vlan-aware[[:space:]]+/) {
					print "    bridge-vlan-aware yes"
					saw_vlan = 1
					continue
				}
				print line
				if (!saw_vlan && line ~ /^[[:space:]]*bridge-fd[[:space:]]+/) {
					print "    bridge-vlan-aware yes"
					saw_vlan = 1
				}
			}
		}

		function flush_target() {
			if (!capturing) {
				return
			}
			emit_target()
			delete buf
			count = 0
			capturing = 0
		}

		{
			if (capturing) {
				if ($0 == "") {
					flush_target()
					print ""
					next
				}
				if ($0 ~ /^(auto|iface|source)[[:space:]]+/) {
					flush_target()
				} else {
					buf[++count] = $0
					next
				}
			}

			if ($0 == "iface " bridge " inet manual") {
				capturing = 1
				buf[++count] = $0
				next
			}

			print
		}

		END {
			flush_target()
		}
	' /etc/network/interfaces >"$tmp_file"

	mv "$tmp_file" /etc/network/interfaces
	chmod 644 /etc/network/interfaces
}

lan_bridge_uses_target_port() {
	local ports
	ports="$(bridge_ports_for "$LAN_BR" | tr '\n' ' ')"
	[ -n "$ports" ] || return 1
	echo "$ports" | grep -qw "$LAN_NIC"
}

existing_lan_bridge() {
	local bridge
	for bridge in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep '^vmbr' || true); do
		if ip -4 addr show "$bridge" 2>/dev/null | grep -q "inet ${LAN_V4_IP}/"; then
			echo "$bridge"
			return
		fi
	done
}

check_ip_conflicts() {
	log_info "Checking for IP address conflicts..."

	local candidate_prefix candidate_third existing_cidrs cidr wan_ip_current base_a base_b
	candidate_prefix="${LAN_V4#*/}"
	base_a="$(echo "${LAN_V4%%/*}" | cut -d. -f1)"
	base_b="$(echo "${LAN_V4%%/*}" | cut -d. -f2)"
	candidate_third="$(echo "${LAN_V4%%/*}" | cut -d. -f3)"
	existing_cidrs="$(ip -o -4 addr show 2>/dev/null | awk -v lan="$LAN_BR" '$2 != lan {print $4}' || true)"

	wan_ip_current=$(ip -4 addr show "${WAN_BR}" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }' || true)
	if [ -n "$wan_ip_current" ] && ! echo "$existing_cidrs" | grep -q "^${wan_ip_current}/"; then
		existing_cidrs="${existing_cidrs}
${wan_ip_current}/24"
	fi

	while :; do
		local candidate="${base_a}.${base_b}.${candidate_third}.1/${candidate_prefix}"
		local conflict=false
		while IFS= read -r cidr; do
			[ -n "$cidr" ] || continue
			if cidr_overlaps "$candidate" "$cidr"; then
				conflict=true
				break
			fi
		done <<-EOF
		$existing_cidrs
		EOF

		if ! $conflict; then
			if [ "$candidate" != "$LAN_V4" ]; then
				log_warn "LAN network conflict detected, adjusted LAN to ${candidate}"
				LAN_V4="$candidate"
				LAN_V4_IP=""
				LAN_V4_BRD=""
				LAN_V4_NET=""
				DHCP_V4_START=""
				DHCP_V4_END=""
				LAN_V6_PREFIX=""
				LAN_V6_ROUTER_IP=""
				LAN_V6_RANGE_LOW=""
				LAN_V6_RANGE_HIGH=""
				derive_config_values
			fi
			break
		fi

		candidate_third=$((candidate_third + 1))
		if [ "$candidate_third" -gt 254 ]; then
			log_fatal "Unable to find a free ${base_a}.${base_b}.x.0/${candidate_prefix} LAN subnet"
		fi
	done

	return 0
}

################################################################################
# CONFIGURATION FILE MANAGEMENT
################################################################################

create_config_file() {
	log_info "Creating configuration file: $CONFIG_FILE"

	local config_mail_relay_host config_smtp_relay config_postfix_smtp_relay
	config_mail_relay_host="${MAIL_RELAY_HOST}"
	config_smtp_relay="${SMTP_RELAY}"
	config_postfix_smtp_relay="${POSTFIX_SMTP_RELAY}"
	[ "$config_mail_relay_host" = "mail.example.com" ] && config_mail_relay_host=""
	[ "$config_smtp_relay" = "mail.example.com" ] && config_smtp_relay=""
	[ "$config_postfix_smtp_relay" = "mail.example.com" ] && config_postfix_smtp_relay=""

	cat >"$CONFIG_FILE" <<-EOF
		# Proxmox Bootstrap Configuration
		# Generated: $(date)
		# Version: $SCRIPT_VERSION

		# Network Configuration
		WAN_NIC="${WAN_NIC}"
		LAN_NIC="${LAN_NIC}"
		ROUTER_NIC="${ROUTER_NIC}"
		WAN_BR="${WAN_BR}"
		LAN_BR="${LAN_BR}"
		ROUTER_BR="${ROUTER_BR}"

		# WAN IPv4
		WAN_V4="${WAN_V4}"
		WAN_V4_GW="${WAN_V4_GW}"
		WAN_V4_BRD="${WAN_V4_BRD}"

		# WAN IPv6
		WAN_V6="${WAN_V6}"
		WAN_V6_GW="${WAN_V6_GW}"

		# LAN IPv4
		LAN_V4="${LAN_V4}"
		LAN_V4_BRD="${LAN_V4_BRD}"
		LAN_V4_NET="${LAN_V4_NET}"
		DHCP_V4_START="${DHCP_V4_START}"
		DHCP_V4_END="${DHCP_V4_END}"
		LAN_DOMAIN="${LAN_DOMAIN}"

		# LAN IPv6
		LAN_V6_PREFIX="${LAN_V6_PREFIX}"
		LAN_V6_ROUTER_IP="${LAN_V6_ROUTER_IP}"
		LAN_V6_STATEFUL="${LAN_V6_STATEFUL}"
		LAN_V6_RANGE_LOW="${LAN_V6_RANGE_LOW}"
		LAN_V6_RANGE_HIGH="${LAN_V6_RANGE_HIGH}"
		LAN_IPV6_IS_ULA="${LAN_IPV6_IS_ULA}"
		NAT66_ENABLE="${NAT66_ENABLE}"

		# DNS Forwarders
		FWD1="${FWD1}"
		FWD2="${FWD2}"
		FWD3="${FWD3}"

		# Mail Configuration
		MAIL_RELAY_HOST="${config_mail_relay_host}"
		MAIL_RELAY_PORT="${MAIL_RELAY_PORT}"
		ROOT_MAIL_FORWARD="${ROOT_MAIL_FORWARD}"
		SMTP_RELAY="${config_smtp_relay}"
		SMTP_PORT="${SMTP_PORT}"
		ROOT_EMAIL="${ROOT_EMAIL}"
		CONFIGURE_POSTFIX="${CONFIGURE_POSTFIX}"
		POSTFIX_SERVER_TYPE="${POSTFIX_SERVER_TYPE}"
		POSTFIX_SMTP_RELAY="${config_postfix_smtp_relay}"
		POSTFIX_SMTP_PORT="${POSTFIX_SMTP_PORT}"
		POSTFIX_FROM_EMAIL="${POSTFIX_FROM_EMAIL}"
		POSTFIX_FROM_NAME="${POSTFIX_FROM_NAME}"
		POSTFIX_ROOT_FORWARD="${POSTFIX_ROOT_FORWARD}"
		POSTFIX_MYHOSTNAME="${POSTFIX_MYHOSTNAME}"
		POSTFIX_MYDOMAIN="${POSTFIX_MYDOMAIN}"
		POSTFIX_RELAY_TLS="${POSTFIX_RELAY_TLS}"
		POSTFIX_RELAY_USERNAME="${POSTFIX_RELAY_USERNAME}"
		POSTFIX_RELAY_PASSWORD="${POSTFIX_RELAY_PASSWORD}"
		POSTFIX_WAN_ENABLE="${POSTFIX_WAN_ENABLE}"
		POSTFIX_FORWARD_HOST="${POSTFIX_FORWARD_HOST}"
		POSTFIX_FORWARD_PORTS="${POSTFIX_FORWARD_PORTS}"

		# DNS/DHCP/RA Service Modes
		DNS_SERVER_TYPE="${DNS_SERVER_TYPE}"
		DNS_FORWARD_HOST="${DNS_FORWARD_HOST}"
		DNS_FORWARD_PORTS="${DNS_FORWARD_PORTS}"
		DNS_SPLIT_ENABLE="${DNS_SPLIT_ENABLE}"
		DNS_WAN_ENABLE="${DNS_WAN_ENABLE}"
		DNS_WAN_ZONE="${DNS_WAN_ZONE}"
		DNS_WAN_RECORDS_FILE="${DNS_WAN_RECORDS_FILE}"
		DNS_LAN_RECURSION="${DNS_LAN_RECURSION}"
		DNS_WAN_RECURSION="${DNS_WAN_RECURSION}"
		DHCP_SERVER_TYPE="${DHCP_SERVER_TYPE}"
		DHCP_RELAY_HOST="${DHCP_RELAY_HOST}"
		DHCP_RELAY_INTERFACES="${DHCP_RELAY_INTERFACES}"
		RA_SERVER_TYPE="${RA_SERVER_TYPE}"

		# Node/Guest Defaults
		PVE_NODE_NAME="${PVE_NODE_NAME}"
		FORCE_NODE_RENAME="${FORCE_NODE_RENAME}"
		GUEST_DEFAULT_BRIDGE="${GUEST_DEFAULT_BRIDGE}"

		# Feature Flags
		DOWNLOAD_ISOS="${DOWNLOAD_ISOS}"
		DOWNLOAD_TEMPLATES="${DOWNLOAD_TEMPLATES}"
		RUN_PROXMENUX="${RUN_PROXMENUX}"
		RUN_POST_INSTALL="${RUN_POST_INSTALL}"
		CONFIGURE_SDN="${CONFIGURE_SDN}"
		DISABLE_SUBSCRIPTION_NAG="${DISABLE_SUBSCRIPTION_NAG}"
		AUTO_DIST_UPGRADE="${AUTO_DIST_UPGRADE}"
		PIN_NEWEST_PVE_KERNEL="${PIN_NEWEST_PVE_KERNEL}"
		PVE_KERNEL_KEEP_COUNT="${PVE_KERNEL_KEEP_COUNT}"
		ENABLE_NESTED_VIRT="${ENABLE_NESTED_VIRT}"
	EOF

	chown root:root "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"
	log_success "Configuration file created"
}

load_config_file() {
	if [ -f "$CONFIG_FILE" ]; then
		log_info "Loading configuration from: $CONFIG_FILE"
		load_assignment_file "$CONFIG_FILE"
	fi
	if [ -f "$ENV_FILE" ]; then
		log_info "Loading environment overrides from: $ENV_FILE"
		load_assignment_file "$ENV_FILE"
	fi
	load_resolved_network_state
	derive_config_values
}

state_task_done() {
	local task="$1"
	[ -f "$STATE_FILE" ] || return 1
	awk -F'|' -v task="$task" '$1 == task { found = 1; exit 0 } END { exit(found ? 0 : 1) }' "$STATE_FILE"
}

with_state_lock() {
	local lock_file lock_dir
	local rc
	lock_file="${STATE_FILE}.lock"
	lock_dir="${lock_file}.d"

	if command_exists flock; then
		(
			flock -x 9
			"$@"
		) 9>"$lock_file"
	else
		while ! mkdir "$lock_dir" 2>/dev/null; do
			sleep 0.1
		done
		"$@"
		rc=$?
		rmdir "$lock_dir"
		return "$rc"
	fi
}

write_task_state() {
	local task="$1"
	local tmp_file
	mkdir -p "$(dirname "$STATE_FILE")"
	tmp_file="$(mktemp)"
	if [ -f "$STATE_FILE" ]; then
		awk -F'|' -v task="$task" '$1 != task' "$STATE_FILE" >"$tmp_file"
	fi
	printf '%s|%s\n' "$task" "$(date '+%Y-%m-%d %H:%M:%S')" >>"$tmp_file"
	mv "$tmp_file" "$STATE_FILE"
}

remove_task_state() {
	local task="$1"
	local tmp_file
	tmp_file="$(mktemp)"
	awk -F'|' -v task="$task" '$1 != task' "$STATE_FILE" >"$tmp_file"
	mv "$tmp_file" "$STATE_FILE"
}

mark_task_done() {
	local task="$1"
	with_state_lock write_task_state "$task"
}

run_task() {
	local task="$1"
	local fn="$2"

	if ! $FORCE_MODE && state_task_done "$task"; then
		log_info "Skipping completed task: $task"
		return 0
	fi

	"$fn"
	mark_task_done "$task"
}

show_status() {
	if [ ! -f "$STATE_FILE" ]; then
		echo "No completed tasks recorded."
		return 0
	fi

	echo "Completed tasks:"
	while IFS='|' read -r task completed_at; do
		[ -n "$task" ] || continue
		echo "  - $task (completed: $completed_at)"
	done <"$STATE_FILE"
}

clear_state() {
	local task="${1:-}"

	if [ -z "$task" ]; then
		rm -f "$STATE_FILE"
		rm -f "${STATE_FILE}.lock"
		rmdir "${STATE_FILE}.lock.d" 2>/dev/null || true
		echo "Cleared all state."
		return 0
	fi

	if [ ! -f "$STATE_FILE" ]; then
		echo "No state file exists."
		return 0
	fi

	with_state_lock remove_task_state "$task"
	echo "Cleared state for task: $task"
}

reset_bootstrap() {
	mkdir -p "$LOG_DIR" "$BACKUP_DIR"
	log_warn "Resetting Proxmox bootstrap-managed configuration"

	local file
	local -a packages
	for file in \
		/etc/nftables.conf \
		/etc/bind/named.conf \
		/etc/bind/zones.conf \
		/etc/bind/dhcp.key \
		/etc/bind/rndc.key \
		/etc/dhcp/dhcpd.conf \
		/etc/dhcp/dhcpd6.conf \
		/etc/default/isc-dhcp-server \
		/etc/default/isc-dhcp-relay \
		/etc/radvd.conf \
		/etc/sysctl.d/99-proxmox-bootstrap.conf \
		/etc/apt/apt.conf.d/99-proxmox-bootstrap-firmware-warning \
		/etc/apt/apt.conf.d/99-proxmox-bootstrap-disable-nag \
		/usr/local/sbin/proxmox-bootstrap-disable-nag \
		/etc/modprobe.d/proxmox-bootstrap-kvm.conf \
		/etc/letsencrypt/renewal-hooks/deploy/proxmox-bootstrap-copy-pve-cert \
		/etc/nginx/nginx.conf \
		/etc/proxmox-bootstrap.conf; do
		backup_file "$file"
		rm -f "$file"
	done

	if [ -d /etc/pve/sdn ]; then
		backup_file /etc/pve/sdn/sdn.cfg
		backup_file /etc/pve/sdn/ipam.cfg
		rm -f /etc/pve/sdn/sdn.cfg /etc/pve/sdn/ipam.cfg
	fi

	if [ -d "$OPTIONAL_TOOLS_DIR" ]; then
		mkdir -p "${BACKUP_DIR}${OPTIONAL_TOOLS_DIR}"
		cp -a "$OPTIONAL_TOOLS_DIR"/. "${BACKUP_DIR}${OPTIONAL_TOOLS_DIR}/" 2>/dev/null || true
		rm -rf "$OPTIONAL_TOOLS_DIR"
	fi

	rm -f /etc/fail2ban/jail.d/proxmox-bootstrap.conf
	rm -f /etc/modules-load.d/proxmox-bootstrap.conf
	rm -rf /etc/systemd/system/named.service.d
	if [ -d /etc/nginx ]; then
		mkdir -p "${BACKUP_DIR}/etc"
		cp -a /etc/nginx "${BACKUP_DIR}/etc/" 2>/dev/null || true
		find /etc/nginx -mindepth 1 ! -name mime.types -exec rm -rf {} +
	fi

	systemctl disable --now bind9 isc-dhcp-server isc-dhcp-relay radvd postfix nftables fail2ban nginx >/dev/null 2>&1 || true

	packages=(
		bind9 bind9-utils dnsutils isc-dhcp-server isc-dhcp-relay radvd postfix
		mailutils fail2ban apparmor-utils libpve-network-perl nginx
	)
	DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}" >/dev/null 2>&1 || log_warn "Some bootstrap-managed packages could not be purged"
	DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true

	rm -f "$STATE_FILE"
	rm -f "$RESOLVED_NETWORK_STATE_FILE"
	log_success "Reset complete; backups preserved at $BACKUP_DIR"
}

usage() {
	cat <<-EOF
		Usage: $0 [options]

		Options:
		  --init                 Create $CONFIG_FILE and exit
		  --status               Show completed bootstrap tasks
		  --clear-state [task]   Clear all state or one task
		  --reset                Remove managed configuration and state
		  --force                Re-run tasks even when state says complete
		  --help                 Show this help
	EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--init)
			mkdir -p "$LOG_DIR" "$BACKUP_DIR"
			load_config_file
			create_config_file
			exit 0
			;;
		--status)
			show_status
			exit 0
			;;
		--clear-state)
			if [ "${2:-}" != "" ] && [ "${2#--}" = "$2" ]; then
				CLEAR_STATE_TASK="$2"
				shift
			fi
			clear_state "$CLEAR_STATE_TASK"
			exit 0
			;;
		--reset)
			reset_bootstrap
			exit 0
			;;
		--force)
			FORCE_MODE=true
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
		esac
		shift
	done
}

################################################################################
# REPOSITORY CONFIGURATION
################################################################################

configure_repositories() {
	log_info "Configuring Proxmox repositories..."

	DEBIAN_CODENAME=$(get_debian_codename)
	log_info "Detected: Proxmox VE $PVE_MAJOR_VERSION (Debian $DEBIAN_CODENAME)"

	if [ "$PVE_MAJOR_VERSION" -ge 9 ]; then
		configure_repositories_deb822
	else
		configure_repositories_legacy
	fi
	configure_firmware_warning_suppression

	log_info "Updating package lists..."
	DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || {
		log_error "Failed to update package lists"
		return 1
	}

	log_success "Repositories configured"
	add_summary "Configured Proxmox repositories with no-subscription defaults"
}

configure_firmware_warning_suppression() {
	backup_file "/etc/apt/apt.conf.d/99-proxmox-bootstrap-firmware-warning"
	cat >/etc/apt/apt.conf.d/99-proxmox-bootstrap-firmware-warning <<-EOF
		APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";
	EOF
}

configure_repositories_deb822() {
	backup_file "/etc/apt/sources.list"
	: >/etc/apt/sources.list

	backup_file "/etc/apt/sources.list.d/debian.sources"
	cat >/etc/apt/sources.list.d/debian.sources <<-EOF
		Types: deb
		URIs: http://deb.debian.org/debian/
		Suites: ${DEBIAN_CODENAME} ${DEBIAN_CODENAME}-updates
		Components: main contrib non-free non-free-firmware
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

		Types: deb
		URIs: http://security.debian.org/debian-security/
		Suites: ${DEBIAN_CODENAME}-security
		Components: main contrib non-free non-free-firmware
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
	EOF

	backup_file "/etc/apt/sources.list.d/pve-enterprise.sources"
	cat >/etc/apt/sources.list.d/pve-enterprise.sources <<-EOF
		# Types: deb
		# URIs: https://enterprise.proxmox.com/debian/pve
		# Suites: ${DEBIAN_CODENAME}
		# Components: pve-enterprise
		# Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
	EOF

	if [ -f "/etc/apt/sources.list.d/pve-install-repo.sources" ]; then
		backup_file "/etc/apt/sources.list.d/pve-install-repo.sources"
		: >/etc/apt/sources.list.d/pve-install-repo.sources
	fi

	cat >/etc/apt/sources.list.d/pve-no-subscription.sources <<-EOF
		Types: deb
		URIs: http://download.proxmox.com/debian/pve
		Suites: ${DEBIAN_CODENAME}
		Components: pve-no-subscription
		Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
	EOF

	if [ -f "/etc/apt/sources.list.d/ceph.sources" ]; then
		backup_file "/etc/apt/sources.list.d/ceph.sources"
		: >/etc/apt/sources.list.d/ceph.sources
	fi
}

configure_repositories_legacy() {
	backup_file "/etc/apt/sources.list"
	cat >/etc/apt/sources.list <<-EOF
		deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
		deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
		deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
	EOF

	backup_file "/etc/apt/sources.list.d/pve-enterprise.list"
	echo "# deb https://enterprise.proxmox.com/debian/pve ${DEBIAN_CODENAME} pve-enterprise" >/etc/apt/sources.list.d/pve-enterprise.list

	if [ -f "/etc/apt/sources.list.d/pve-install-repo.list" ]; then
		backup_file "/etc/apt/sources.list.d/pve-install-repo.list"
		: >/etc/apt/sources.list.d/pve-install-repo.list
	fi

	cat >/etc/apt/sources.list.d/pve-no-subscription.list <<-EOF
		deb http://download.proxmox.com/debian/pve ${DEBIAN_CODENAME} pve-no-subscription
	EOF

	if [ -f "/etc/apt/sources.list.d/ceph.list" ]; then
		backup_file "/etc/apt/sources.list.d/ceph.list"
		: >/etc/apt/sources.list.d/ceph.list
	fi
}

################################################################################
# PACKAGE INSTALLATION
################################################################################

install_package() {
	local pkg="$1"

	if dpkg -s "$pkg" >/dev/null 2>&1; then
		return 0
	fi

	log_info "Installing $pkg..."
	run_apt_noninteractive apt-get install -y --no-install-recommends \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" \
		"$pkg" || {
		log_error "Failed to install: $pkg"
		return 1
	}
	log_success "Installed $pkg"
}

install_packages() {
	log_info "Installing packages..."

	local base_packages="vim sudo curl wget ca-certificates net-tools iproute2 iputils-ping screen jq bash-completion gawk rsync openssl"
	local network_packages="nftables bridge-utils ifupdown2"
	local service_packages="fail2ban apparmor apparmor-utils"
	local optional_packages=""

	if [ "$DNS_SERVER_TYPE" = "local" ]; then
		service_packages="${service_packages} bind9 bind9-utils dnsutils"
	else
		base_packages="${base_packages} dnsutils"
	fi

	if [ "$DHCP_SERVER_TYPE" = "local" ]; then
		service_packages="${service_packages} isc-dhcp-server"
	elif [ "$DHCP_SERVER_TYPE" = "relay" ]; then
		service_packages="${service_packages} isc-dhcp-relay"
	fi

	if [ "$RA_SERVER_TYPE" = "local" ]; then
		service_packages="${service_packages} radvd"
	fi

	if is_enabled "$CONFIGURE_POSTFIX" && [ "$POSTFIX_SERVER_TYPE" != "forward" ]; then
		optional_packages="${optional_packages} postfix mailutils"
	fi

	if is_enabled "$CONFIGURE_SDN"; then
		optional_packages="${optional_packages} libpve-network-perl"
	fi
	optional_packages="${optional_packages} nginx"

	for pkg in $base_packages $network_packages $service_packages $optional_packages; do
		install_package "$pkg" || true
	done

	log_success "Package installation complete"
}

upgrade_system() {
	log_info "Applying non-interactive package upgrade..."

	run_apt_noninteractive apt-get dist-upgrade -y \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" || {
		log_error "Failed to complete package upgrade"
		return 1
	}

	log_success "System packages upgraded"
	add_summary "Applied non-interactive package upgrade"
}

configure_kernel_policy() {
	if ! is_enabled "$PIN_NEWEST_PVE_KERNEL" && [ "${PVE_KERNEL_KEEP_COUNT:-0}" -lt 1 ]; then
		return 0
	fi

	local packages versions newest current backup pkg version
	packages="$(list_installed_pve_kernel_packages)"
	if [ -z "$packages" ]; then
		log_info "No installed Proxmox kernel image packages detected"
		return 0
	fi

	versions="$(
		printf '%s\n' "$packages" |
			while IFS= read -r pkg; do
				kernel_version_from_package "$pkg"
			done | awk 'NF' | sort -Vu
	)"
	newest="$(printf '%s\n' "$versions" | tail -1)"
	current="$(uname -r)"
	backup=""

	if [ "${PVE_KERNEL_KEEP_COUNT:-2}" -gt 1 ]; then
		if printf '%s\n' "$versions" | grep -Fxq "$current" && [ "$current" != "$newest" ]; then
			backup="$current"
		else
			backup="$(printf '%s\n' "$versions" | grep -Fvx "$newest" | tail -1 || true)"
		fi
	fi

	log_info "Applying Proxmox kernel policy..."
	if is_enabled "$PIN_NEWEST_PVE_KERNEL" && command_exists proxmox-boot-tool; then
		proxmox-boot-tool kernel pin "$newest" >/dev/null 2>&1 || {
			log_error "Failed to pin newest installed kernel: $newest"
			return 1
		}
		add_summary "Pinned newest installed kernel: ${newest}"
	fi

	local -a remove_pkgs=()
	while IFS= read -r pkg; do
		version="$(kernel_version_from_package "$pkg")"
		if [ "$version" = "$newest" ] || { [ -n "$backup" ] && [ "$version" = "$backup" ]; }; then
			continue
		fi
		remove_pkgs+=("$pkg")
	done <<-EOF
	$packages
	EOF

	if [ "${#remove_pkgs[@]}" -gt 0 ]; then
		DEBIAN_FRONTEND=noninteractive apt-get purge -y "${remove_pkgs[@]}" >/dev/null 2>&1 || {
			log_error "Failed to remove old Proxmox kernel packages"
			return 1
		}
		add_summary "Removed old Proxmox kernel packages: ${remove_pkgs[*]}"
	fi

	if command_exists proxmox-boot-tool; then
		proxmox-boot-tool refresh >/dev/null 2>&1 || {
			log_error "Failed to refresh proxmox-boot-tool after kernel changes"
			return 1
		}
	fi

	configure_nested_virtualization

	if [ -n "$backup" ]; then
		add_summary "Retained Proxmox kernels: ${newest}, ${backup}"
	else
		add_summary "Retained Proxmox kernel: ${newest}"
	fi

	log_success "Proxmox kernel policy applied"
}

################################################################################
# NETWORK CONFIGURATION
################################################################################

is_network_configured() {
	lan_bridge_uses_target_port || return 1
	router_bridge_uses_target_port || return 1
	router_bridge_vlan_aware_configured || return 1

	if $SINGLE_NIC_MODE; then
		ip link show "$LAN_NIC" >/dev/null 2>&1 && ip link show "$LAN_BR" >/dev/null 2>&1
	else
		ip link show "$WAN_BR" >/dev/null 2>&1 && ip link show "$LAN_BR" >/dev/null 2>&1 && { [ -z "$ROUTER_BR" ] || ip link show "$ROUTER_BR" >/dev/null 2>&1; }
	fi
}

configure_network() {
	if is_network_configured; then
		log_info "Network already configured, skipping"
		return 0
	fi

	log_info "Configuring network interfaces..."

	configure_network_additive

	log_info "Reloading network configuration (may cause brief disconnection)..."
	reload_network_config || log_warn "network reload reported errors"

	if ! is_network_configured && command_exists ifup; then
		if is_dummy_lan_iface "$LAN_NIC"; then
			ifup "$LAN_NIC" 2>/dev/null || true
		fi
		if is_router_dummy_iface "$ROUTER_NIC"; then
			ifup "$ROUTER_NIC" 2>/dev/null || true
		fi
		ifup "$LAN_BR" 2>/dev/null || true
		[ -n "$ROUTER_BR" ] && ifup "$ROUTER_BR" 2>/dev/null || true
	fi

	if is_network_configured; then
		log_success "Network configured successfully"
	else
		log_error "Network configuration may have failed"
		return 1
	fi
}

configure_network_additive() {
	backup_file "/etc/network/interfaces"

	if is_dummy_lan_iface "$LAN_NIC"; then
		modprobe dummy 2>/dev/null || true
		if ! grep -q "^dummy$" /etc/modules 2>/dev/null; then
			echo "dummy" >>/etc/modules
		fi

		if ! ip link show "$LAN_NIC" >/dev/null 2>&1; then
			ip link add "$LAN_NIC" type dummy || true
		fi
	fi

	if is_router_dummy_iface "$ROUTER_NIC"; then
		modprobe dummy 2>/dev/null || true
		if ! grep -q "^dummy$" /etc/modules 2>/dev/null; then
			echo "dummy" >>/etc/modules
		fi

		if ! ip link show "$ROUTER_NIC" >/dev/null 2>&1; then
			ip link add "$ROUTER_NIC" type dummy || true
		fi
	fi

	if ! grep -q "^auto ${WAN_BR}$" /etc/network/interfaces 2>/dev/null && [ -n "$WAN_NIC" ] && { [ -n "$WAN_V4" ] || [ -n "$WAN_V6" ]; }; then
		append_wan_bridge
	fi

	if ! grep -q "^auto ${LAN_NIC}$" /etc/network/interfaces 2>/dev/null; then
		append_manual_iface "$LAN_NIC"
	fi

	if ! grep -q "^auto ${LAN_BR}$" /etc/network/interfaces 2>/dev/null; then
		append_lan_bridge
	fi

	ensure_lan_bridge_settings

	if [ -n "$ROUTER_NIC" ] && ! grep -q "^auto ${ROUTER_NIC}$" /etc/network/interfaces 2>/dev/null; then
		append_manual_iface "$ROUTER_NIC"
	fi

	if [ -n "$ROUTER_BR" ] && ! grep -q "^auto ${ROUTER_BR}$" /etc/network/interfaces 2>/dev/null; then
		append_router_bridge
	fi

	ensure_router_bridge_settings

	if ! grep -q "^source /etc/network/interfaces.d/\*" /etc/network/interfaces 2>/dev/null; then
		printf '\nsource /etc/network/interfaces.d/*\n' >>/etc/network/interfaces
	fi
}

append_manual_iface() {
	local iface="$1"
	if is_dummy_lan_iface "$iface"; then
		cat >>/etc/network/interfaces <<-EOF

			auto ${iface}
			iface ${iface} inet manual
			    pre-up ip link add ${iface} type dummy 2>/dev/null || true
		EOF
	else
		cat >>/etc/network/interfaces <<-EOF

			auto ${iface}
			iface ${iface} inet manual
		EOF
	fi
}

append_wan_bridge() {
	cat >>/etc/network/interfaces <<-EOF

		auto ${WAN_BR}
		iface ${WAN_BR} inet static
		    address ${WAN_V4}
		    broadcast ${WAN_V4_BRD}
		    gateway ${WAN_V4_GW}
		    bridge-ports ${WAN_NIC}
		    bridge-stp off
		    bridge-fd 0
		    # Proxmox bootstrap WAN bridge for host uplink
	EOF
	if [ -n "$WAN_V6" ]; then
		cat >>/etc/network/interfaces <<-EOF

			iface ${WAN_BR} inet6 static
			    address ${WAN_V6}
			    gateway ${WAN_V6_GW}
		EOF
	fi
}

append_lan_bridge() {
	cat >>/etc/network/interfaces <<-EOF

		auto ${LAN_BR}
		iface ${LAN_BR} inet static
		    address ${LAN_V4}
		    broadcast ${LAN_V4_BRD}
		    bridge-ports ${LAN_NIC}
		    bridge-stp off
		    bridge-fd 0
		    # Proxmox bootstrap LAN bridge for guests

		iface ${LAN_BR} inet6 static
		    address ${LAN_V6_ROUTER_IP}/64
	EOF
}

append_router_bridge() {
	cat >>/etc/network/interfaces <<-EOF

		auto ${ROUTER_BR}
		iface ${ROUTER_BR} inet manual
		    bridge-ports ${ROUTER_NIC}
		    bridge-stp off
		    bridge-fd 0
		    bridge-vlan-aware yes
		    # Proxmox bootstrap router-lab bridge for pfSense and downstream guests
	EOF
}

################################################################################
# MAIN EXECUTION
################################################################################

################################################################################
# SYSCTL CONFIGURATION
################################################################################

configure_sysctl() {
	log_info "Configuring system parameters..."
	
	cat > /etc/sysctl.d/99-proxmox-bootstrap.conf <<-EOF
	# IPv4 forwarding
	net.ipv4.ip_forward=1
	net.ipv4.conf.all.forwarding=1
	
	# IPv6 forwarding
	net.ipv6.conf.all.forwarding=1
	net.ipv6.conf.default.forwarding=1
	
	# Memory overcommit for virtualization
	vm.overcommit_memory=1
	vm.overcommit_ratio=100
	
	# Kernel same-page merging (KSM) for memory deduplication
	kernel.sched_autogroup_enabled=0
	
	# Network performance tuning
	net.core.netdev_max_backlog=5000
	net.core.rmem_max=134217728
	net.core.wmem_max=134217728
	net.ipv4.tcp_rmem=4096 87380 67108864
	net.ipv4.tcp_wmem=4096 65536 67108864
	EOF
	
	sysctl --system >/dev/null 2>&1
	
	log_success "System parameters configured"
}

################################################################################
# SSH CONFIGURATION
################################################################################

configure_ssh() {
	log_info "Optimizing SSH configuration..."
	
	backup_file /etc/ssh/sshd_config
	
	if ! grep -qE "^[[:space:]]*MaxStartups" /etc/ssh/sshd_config; then
		echo "MaxStartups 100:30:200" >> /etc/ssh/sshd_config
	else
		sed -i 's/^[[:space:]]*MaxStartups.*/MaxStartups 100:30:200/' /etc/ssh/sshd_config
	fi
	
	if ! grep -qE "^[[:space:]]*ClientAliveInterval" /etc/ssh/sshd_config; then
		echo "ClientAliveInterval 60" >> /etc/ssh/sshd_config
	else
		sed -i 's/^[[:space:]]*ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
	fi
	
	if ! grep -qE "^[[:space:]]*ClientAliveCountMax" /etc/ssh/sshd_config; then
		echo "ClientAliveCountMax 10" >> /etc/ssh/sshd_config
	else
		sed -i 's/^[[:space:]]*ClientAliveCountMax.*/ClientAliveCountMax 10/' /etc/ssh/sshd_config
	fi
	
	systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
	
	log_success "SSH configured"
}

configure_fail2ban() {
	log_info "Configuring fail2ban..."
	if ! command_exists fail2ban-server; then
		log_warn "fail2ban is not installed, skipping"
		return 0
	fi

	mkdir -p /etc/fail2ban/jail.d
	cat >/etc/fail2ban/jail.d/proxmox-bootstrap.conf <<-EOF
		[sshd]
		enabled = true
		mode = normal
		port = ssh
		filter = sshd
		logpath = %(sshd_log)s
		maxretry = 5
		bantime = 1h
		findtime = 10m
	EOF
	unmask_service_if_needed fail2ban
	systemctl enable fail2ban >/dev/null 2>&1 || true
	systemctl restart fail2ban || log_warn "Failed to restart fail2ban"
	log_success "fail2ban configured"
}

configure_subscription_nag() {
	if ! is_enabled "$DISABLE_SUBSCRIPTION_NAG"; then
		log_info "Subscription nag removal disabled by config"
		return 0
	fi

	log_info "Configuring subscription nag removal..."
	cat >/usr/local/sbin/proxmox-bootstrap-disable-nag <<-'EOF'
		#!/usr/bin/env bash
		set -euo pipefail
		for file in \
			/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js \
			/usr/share/pve-manager/js/pvemanagerlib.js; do
			[ -f "$file" ] || continue
			cp -a "$file" "${file}.proxmox-bootstrap.bak" 2>/dev/null || true
			sed -i \
				-e "s/res\\.data\\.status\\.toLowerCase() !== 'active'/false/g" \
				-e 's/res\.data\.status\.toLowerCase() !== "active"/false/g' \
				-e "s/data\\.status !== 'Active'/false/g" \
				-e 's/data\.status !== "Active"/false/g' \
				-e "s/data\\.status\\.toLowerCase() !== 'active'/false/g" \
				-e 's/data\.status\.toLowerCase() !== "active"/false/g' \
				-e 's/res\.false/false/g' \
				"$file"
		done
		systemctl reload pveproxy >/dev/null 2>&1 || true
	EOF
	chmod 755 /usr/local/sbin/proxmox-bootstrap-disable-nag

	mkdir -p /etc/apt/apt.conf.d
	cat >/etc/apt/apt.conf.d/99-proxmox-bootstrap-disable-nag <<-'EOF'
		DPkg::Post-Invoke { "/usr/local/sbin/proxmox-bootstrap-disable-nag || true"; };
	EOF

	/usr/local/sbin/proxmox-bootstrap-disable-nag || log_warn "Subscription nag patch could not be applied"
	log_success "Subscription nag hook configured"
	add_summary "Enabled upgrade-persistent subscription nag removal"
}

################################################################################
# NFTABLES CONFIGURATION
################################################################################

configure_nftables() {
	log_info "Configuring nftables firewall..."
	
	backup_file /etc/nftables.conf
	local nat66_rules=""
	local wan_mail_input="iifname \"${WAN_BR}\" tcp dport {25, 465, 587} drop"
	local wan_dns_input=""
	local forward_accept_rules=""
	local prerouting_rules=""
	local dns_ports dns_port postfix_forward_ip dns_forward_ip

	if is_enabled "$NAT66_ENABLE"; then
		nat66_rules=$(cat <<-EOF_NAT66

		table ip6 nat {
		  chain postrouting {
		    type nat hook postrouting priority srcnat; policy accept;
		    oifname "$WAN_BR" ip6 saddr ${LAN_V6_PREFIX} masquerade
		  }
		}
		EOF_NAT66
		)
	fi

	if [ "$POSTFIX_SERVER_TYPE" = "internet" ] || is_enabled "$POSTFIX_WAN_ENABLE"; then
		wan_mail_input="iifname \"${WAN_BR}\" tcp dport {25, 465, 587} accept"
	fi

	if [ "$POSTFIX_SERVER_TYPE" = "forward" ] && reachable_host "$POSTFIX_FORWARD_HOST"; then
		local mail_ports
		postfix_forward_ip="$(resolve_ipv4_host "$POSTFIX_FORWARD_HOST" || true)"
		[ -n "$postfix_forward_ip" ] || log_fatal "POSTFIX_FORWARD_HOST must resolve to an IPv4 address for nftables forwarding"
		mail_ports="$(echo "$POSTFIX_FORWARD_PORTS" | tr ',' ' ')"
		wan_mail_input="iifname \"${WAN_BR}\" tcp dport {${POSTFIX_FORWARD_PORTS//,/, }} accept"
		for port in $mail_ports; do
			forward_accept_rules="${forward_accept_rules}
    tcp dport ${port} ip daddr ${postfix_forward_ip} accept"
			prerouting_rules="${prerouting_rules}
    iifname { \"$WAN_BR\", \"$LAN_BR\" } tcp dport ${port} dnat to ${postfix_forward_ip}:${port}"
		done
	fi

	if [ "$DNS_SERVER_TYPE" = "forward" ] && reachable_host "$DNS_FORWARD_HOST"; then
		local dns_iif="iifname \"${LAN_BR}\""
		dns_forward_ip="$(resolve_ipv4_host "$DNS_FORWARD_HOST" || true)"
		[ -n "$dns_forward_ip" ] || log_fatal "DNS_FORWARD_HOST must resolve to an IPv4 address for nftables forwarding"
		dns_ports="$(split_csv_ports "${DNS_FORWARD_PORTS:-53}")"
		if is_enabled "$DNS_WAN_ENABLE"; then
			dns_iif="iifname { \"${WAN_BR}\", \"${LAN_BR}\" }"
			for dns_port in $dns_ports; do
				wan_dns_input="${wan_dns_input}
    iifname \"${WAN_BR}\" udp dport ${dns_port} accept
    iifname \"${WAN_BR}\" tcp dport ${dns_port} accept"
			done
		fi
		for dns_port in $dns_ports; do
			forward_accept_rules="${forward_accept_rules}
    ip daddr ${dns_forward_ip} udp dport ${dns_port} accept
    ip daddr ${dns_forward_ip} tcp dport ${dns_port} accept"
			prerouting_rules="${prerouting_rules}
    ${dns_iif} udp dport ${dns_port} dnat to ${dns_forward_ip}:${dns_port}
    ${dns_iif} tcp dport ${dns_port} dnat to ${dns_forward_ip}:${dns_port}"
		done
	elif is_enabled "$DNS_WAN_ENABLE"; then
		wan_dns_input="iifname \"${WAN_BR}\" udp dport 53 accept
    iifname \"${WAN_BR}\" tcp dport 53 accept"
	fi
	
	cat > /etc/nftables.conf <<-EOF
	#!/usr/sbin/nft -f
	
	flush ruleset
	
	table inet filter {
	  chain input {
	    type filter hook input priority filter; policy drop;
	    
	    ct state invalid drop
	    ct state established,related accept
	    
	    iifname "lo" accept
	    iifname "$LAN_BR" accept
	    
	    ip protocol icmp accept
	    ip6 nexthdr icmpv6 accept
	    
	    iifname "$WAN_BR" tcp dport 22 accept
	    iifname "$WAN_BR" tcp dport 80 accept
	    iifname "$WAN_BR" tcp dport 443 accept
	    iifname "$WAN_BR" tcp dport 8006 accept
	    iifname "$WAN_BR" tcp dport 3128 accept
	    ${wan_dns_input}
	    
	    ${wan_mail_input}
	  }
	  
	  chain forward {
	    type filter hook forward priority filter; policy drop;
	    
	    ct state invalid drop
	    ct state established,related accept
	    
	    iifname "$LAN_BR" oifname "$WAN_BR" accept
	    iifname "$WAN_BR" oifname "$LAN_BR" ct state established,related accept
	    ${forward_accept_rules}
	  }
	  
	  chain output {
	    type filter hook output priority filter; policy accept;
	  }
	}
	
	table ip nat {
	  chain prerouting {
	    type nat hook prerouting priority dstnat; policy accept;
	    ${prerouting_rules}
	  }

	  chain postrouting {
	    type nat hook postrouting priority srcnat; policy accept;
	    oifname "$WAN_BR" ip saddr ${LAN_V4_NET} masquerade
	  }
	}
	${nat66_rules}
	EOF
	
	nft -c -f /etc/nftables.conf || log_fatal "Invalid nftables configuration"
	
	unmask_service_if_needed nftables
	systemctl enable nftables >/dev/null 2>&1 || true
	systemctl restart nftables || log_fatal "Failed to restart nftables"
	
	log_success "Firewall configured"
}

################################################################################
# BIND9 DNS CONFIGURATION
################################################################################

configure_bind9() {
	if [ "$DNS_SERVER_TYPE" = "disabled" ]; then
		log_info "DNS disabled; stopping local BIND9 if present"
		systemctl disable --now bind9 >/dev/null 2>&1 || true
		return 0
	fi
	if [ "$DNS_SERVER_TYPE" = "forward" ]; then
		log_info "DNS forwarding enabled; stopping local BIND9 if present"
		systemctl disable --now bind9 >/dev/null 2>&1 || true
		return 0
	fi

	log_info "Configuring BIND9 DNS server..."
	
	local lan_zone_file reverse_zone_file wan_zone_file listen_v4 listen_v6 default_zone_block trusted_acl
	mkdir -p /etc/bind/keys /var/cache/bind/zones/{primary,secondary,forward,reverse} /var/log/bind /run/named
	chown -R bind:bind /var/cache/bind /var/log/bind /run/named /etc/bind/keys
	chmod 775 /var/log/bind /run/named
	mkdir -p /etc/apparmor.d/local
	touch /etc/apparmor.d/local/usr.sbin.named
	for rule in \
		"/var/log/bind/ rw," \
		"/var/log/bind/** rwk," \
		"/run/named/ rw," \
		"/run/named/** rwk,"; do
		grep -qxF "$rule" /etc/apparmor.d/local/usr.sbin.named || echo "$rule" >>/etc/apparmor.d/local/usr.sbin.named
	done
	if command_exists aa-status && [ -f /etc/apparmor.d/usr.sbin.named ]; then
		apparmor_parser -r /etc/apparmor.d/usr.sbin.named >/dev/null 2>&1 || log_warn "Could not reload AppArmor profile: /etc/apparmor.d/usr.sbin.named"
	fi
	
	if [ ! -f /var/cache/bind/root.cache ]; then
		curl -fsSL https://www.internic.net/domain/named.root -o /var/cache/bind/root.cache 2>/dev/null || true
	fi
	
	log_info "Generating BIND9 TSIG keys..."
	DDNS_KEY=$(openssl rand -base64 32 2>/dev/null | tr -d '\n' || dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n')
	DHCP_KEY=$(openssl rand -base64 64 2>/dev/null | tr -d '\n' || dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '\n')
	RNDC_KEY=$(openssl rand -base64 64 2>/dev/null | tr -d '\n' || dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '\n')
	CERTBOT_KEY=$(openssl rand -base64 64 2>/dev/null | tr -d '\n' || dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '\n')
	BACKUP_KEY=$(openssl rand -base64 64 2>/dev/null | tr -d '\n' || dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '\n')
	log_success "Generated BIND9 keys"
	
	backup_file /etc/bind/named.conf
	backup_file /etc/bind/zones.conf
	cat >/etc/bind/dhcp.key <<-EOF
	key "dhcp-key" { algorithm hmac-sha512; secret "$DHCP_KEY"; };
	EOF
	cat >/etc/bind/rndc.key <<-EOF
	key "rndc-key" { algorithm hmac-sha512; secret "$RNDC_KEY"; };
	EOF
	chmod 600 /etc/bind/dhcp.key /etc/bind/rndc.key
	chown bind:bind /etc/bind/dhcp.key /etc/bind/rndc.key

	SERIAL=$(date +%Y%m%d01)
	REV_ZONE=$(reverse_zone_name "$LAN_V4_NET")
	lan_zone_file="/var/cache/bind/zones/primary/${LAN_DOMAIN}.zone"
	reverse_zone_file="/var/cache/bind/zones/reverse/${REV_ZONE}.zone"
	listen_v4="127.0.0.1; ${LAN_V4_IP};"
	listen_v6="::1; ${LAN_V6_ROUTER_IP};"

	if is_enabled "$DNS_WAN_ENABLE" && [ -n "$WAN_V4_IP" ]; then
		listen_v4="${listen_v4} ${WAN_V4_IP};"
	fi
	if is_enabled "$DNS_WAN_ENABLE" && [ -n "$WAN_V6" ]; then
		listen_v6="${listen_v6} ${WAN_V6%%/*};"
	fi
	trusted_acl="127.0.0.0/8; ::1; ${LAN_V4_NET}; ${LAN_V6_PREFIX};"
	
	cat > /etc/bind/named.conf <<-EOF
	key "ddns-key" { algorithm hmac-sha256; secret "$DDNS_KEY"; };
	key "dhcp-key" { algorithm hmac-sha512; secret "$DHCP_KEY"; };
	key "rndc-key" { algorithm hmac-sha512; secret "$RNDC_KEY"; };
	key "certbot." { algorithm hmac-sha512; secret "$CERTBOT_KEY"; };
	key "backup-key" { algorithm hmac-sha512; secret "$BACKUP_KEY"; };
	
	controls { inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; }; };
	
	acl "all" { 0.0.0.0/0; ::/0; };
	acl "trusted" { ${trusted_acl} };
	acl "updates" { key "dhcp-key"; key "certbot."; key "ddns-key"; };
	acl "transfers" { key "dhcp-key"; key "certbot."; key "backup-key"; trusted; };
	
	options {
	  version "9";
	  listen-on { ${listen_v4} };
	  listen-on-v6 { ${listen_v6} };
	  zone-statistics yes;
	  max-cache-size 60m;
	  interface-interval 60;
	  max-ncache-ttl 10800;
	  max-udp-size 4096;
	  notify yes;
	  allow-transfer { trusted; };
	  transfer-format many-answers;
	  allow-query { trusted; };
	  allow-recursion { trusted; };
	  allow-query-cache { trusted; };
	  auth-nxdomain no;
	  dnssec-validation auto;
	  directory "/var/cache/bind";
	  managed-keys-directory "/etc/bind/keys";
	  pid-file "/run/named/named.pid";
	  dump-file "/var/log/bind/dump.db";
	  statistics-file "/var/log/bind/named.stats";
	  memstatistics-file "/var/log/bind/mem.stats";
	  forwarders { ${FWD1}; ${FWD2}; ${FWD3}; };
	};
	
	logging {
	  channel default_log { file "/var/log/bind/default.log" versions 3 size 5m; severity info; print-time yes; };
	  channel query_log { file "/var/log/bind/query.log" versions 3 size 5m; severity info; print-time yes; };
	  channel update_log { file "/var/log/bind/update.log" versions 3 size 5m; severity info; print-time yes; };
	  channel xfer_log { file "/var/log/bind/xfer.log" versions 3 size 5m; severity info; print-time yes; };
	  channel security_log { file "/var/log/bind/security.log" versions 3 size 5m; severity info; print-time yes; };
	  category default { default_log; };
	  category queries { query_log; };
	  category update { update_log; };
	  category xfer-in { xfer_log; };
	  category xfer-out { xfer_log; };
	  category security { security_log; };
	};
	
	include "/etc/bind/zones.conf";
	EOF

	default_zone_block=$(cat <<-EOF
		zone "." { type hint; file "/var/cache/bind/root.cache"; };

		zone "$LAN_DOMAIN" {
		  type master;
		  file "${lan_zone_file}";
		  allow-update { updates; };
		  allow-transfer { transfers; };
		};
		
		zone "$REV_ZONE" {
		  type master;
		  file "${reverse_zone_file}";
		  allow-update { updates; };
		  allow-transfer { transfers; };
		};
	EOF
	)

	if is_enabled "$DNS_SPLIT_ENABLE" && [ -n "$DNS_WAN_ZONE" ]; then
		wan_zone_file="/var/cache/bind/zones/forward/${DNS_WAN_ZONE}.zone"
		cat > /etc/bind/zones.conf <<-EOF
		view "lan" {
		  match-clients { trusted; };
		  recursion $( [ "$DNS_LAN_RECURSION" = "yes" ] && echo "yes" || echo "no" );
		  ${default_zone_block}
		};

		view "wan" {
		  match-clients { any; };
		  recursion $( [ "$DNS_WAN_RECURSION" = "yes" ] && echo "yes" || echo "no" );
		  zone "." { type hint; file "/var/cache/bind/root.cache"; };
		  zone "${DNS_WAN_ZONE}" {
		    type master;
		    file "${wan_zone_file}";
		    allow-update { none; };
		    allow-transfer { transfers; };
		  };
		};
		EOF
	else
		printf '%s\n' "$default_zone_block" >/etc/bind/zones.conf
	fi
	
	cat > "${lan_zone_file}" <<-EOF
	\$TTL 86400
	@   IN SOA ns1.${LAN_DOMAIN}. hostmaster.${LAN_DOMAIN}. ( $SERIAL 3600 900 1209600 86400 )
	@   IN NS  ns1.${LAN_DOMAIN}.
	ns1 IN A   ${LAN_V4_IP}
	pve IN A   ${LAN_V4_IP}
	gw  IN A   ${LAN_V4_IP}
	$(get_pve_node_name) IN A ${LAN_V4_IP}
	EOF
	
	cat > "${reverse_zone_file}" <<-EOF
	\$TTL 86400
	@   IN SOA ns1.${LAN_DOMAIN}. hostmaster.${LAN_DOMAIN}. ( $SERIAL 3600 900 1209600 86400 )
	@   IN NS  ns1.${LAN_DOMAIN}.
	$(reverse_ptr_owner "$LAN_V4_IP" "$LAN_V4_NET") IN PTR pve.${LAN_DOMAIN}.
	EOF

	if is_enabled "$DNS_SPLIT_ENABLE" && [ -n "$DNS_WAN_ZONE" ]; then
		cat > "${wan_zone_file}" <<-EOF
		\$TTL 86400
		@   IN SOA ns1.${DNS_WAN_ZONE}. hostmaster.${DNS_WAN_ZONE}. ( $SERIAL 3600 900 1209600 86400 )
		@   IN NS  ns1.${DNS_WAN_ZONE}.
		EOF
		if [ -n "$DNS_WAN_RECORDS_FILE" ] && [ -f "$DNS_WAN_RECORDS_FILE" ]; then
			cat "$DNS_WAN_RECORDS_FILE" >>"${wan_zone_file}"
		fi
	fi
	
	chown -R bind:bind /etc/bind /var/cache/bind /var/log/bind /run/named
	
	named-checkconf /etc/bind/named.conf || log_fatal "Invalid BIND configuration"
	named-checkzone "$LAN_DOMAIN" "$lan_zone_file" >/dev/null 2>&1 || log_fatal "Invalid LAN forward zone: $lan_zone_file"
	named-checkzone "$REV_ZONE" "$reverse_zone_file" >/dev/null 2>&1 || log_fatal "Invalid LAN reverse zone: $reverse_zone_file"
	if is_enabled "$DNS_SPLIT_ENABLE" && [ -n "$DNS_WAN_ZONE" ]; then
		named-checkzone "$DNS_WAN_ZONE" "$wan_zone_file" >/dev/null 2>&1 || log_fatal "Invalid WAN zone: $wan_zone_file"
	fi
	
	mkdir -p /etc/systemd/system/named.service.d
	cat > /etc/systemd/system/named.service.d/override.conf <<-'SYSTEMD'
	[Service]
	Type=simple
	TimeoutStartSec=180
	SYSTEMD
	
	systemctl daemon-reload
	unmask_service_if_needed bind9
	systemctl enable bind9 >/dev/null 2>&1 || true
	systemctl restart bind9 || log_fatal "Failed to start BIND9"
	
	sleep 2
	if ! systemctl is-active --quiet bind9; then
		log_error "BIND9 failed to start"
		journalctl -u named -n 20 --no-pager
		log_fatal "DNS server configuration failed"
	fi
	
	log_success "DNS server configured"
}

################################################################################
# DHCP CONFIGURATION
################################################################################

configure_dhcp() {
	if [ "$DHCP_SERVER_TYPE" = "disabled" ]; then
		log_info "DHCP disabled; stopping local ISC DHCP if present"
		systemctl disable --now isc-dhcp-server >/dev/null 2>&1 || true
		systemctl disable --now isc-dhcp-relay >/dev/null 2>&1 || true
		return 0
	fi
	if [ "$DHCP_SERVER_TYPE" = "relay" ]; then
		log_info "Configuring DHCP relay to ${DHCP_RELAY_HOST}"
		systemctl disable --now isc-dhcp-server >/dev/null 2>&1 || true
		if command_exists dhcrelay; then
			backup_file /etc/default/isc-dhcp-relay
			cat >/etc/default/isc-dhcp-relay <<-EOF
				SERVERS="${DHCP_RELAY_HOST}"
				INTERFACES="${DHCP_RELAY_INTERFACES}"
				OPTIONS=""
			EOF
			unmask_service_if_needed isc-dhcp-relay
			systemctl enable isc-dhcp-relay >/dev/null 2>&1 || true
			systemctl restart isc-dhcp-relay || log_warn "Failed to restart DHCP relay"
		else
			log_warn "dhcrelay not available; DHCP relay not configured"
		fi
		return 0
	fi

	log_info "Configuring DHCP servers..."
	systemctl disable --now isc-dhcp-relay >/dev/null 2>&1 || true
	
	local dhcp_reverse_zone dhcp_subnet_mask dhcp_v4_dns_servers dhcp_v6_dns_server
	backup_file /etc/default/isc-dhcp-server
	backup_file /etc/dhcp/dhcpd.conf
	backup_file /etc/dhcp/dhcpd6.conf
	
	cat > /etc/default/isc-dhcp-server <<-EOF
	INTERFACESv4="$LAN_BR"
	INTERFACESv6="$LAN_BR"
	EOF

	if [ "$DNS_SERVER_TYPE" = "disabled" ]; then
		dhcp_v4_dns_servers="${FWD1}, ${FWD2}, ${FWD3}"
		dhcp_v6_dns_server=""
	elif [ "$DNS_SERVER_TYPE" = "forward" ]; then
		dhcp_v4_dns_servers="${LAN_V4_IP}"
		dhcp_v6_dns_server=""
	else
		dhcp_v4_dns_servers="${LAN_V4_IP}"
		dhcp_v6_dns_server="${LAN_V6_ROUTER_IP}"
	fi
	
	DHCP_KEY=""
	if [ "$DNS_SERVER_TYPE" = "local" ]; then
		DHCP_KEY=$(awk -F'secret "' '/^key "dhcp-key"/ { split($2, a, "\""); print a[1]; exit }' /etc/bind/named.conf)
		if [ -z "$DHCP_KEY" ]; then
			log_fatal "Unable to read BIND DHCP TSIG key"
		fi
	fi
	
	cat > /etc/dhcp/dhcpd.conf <<-EOF
	authoritative;
	default-lease-time 3600;
	max-lease-time 86400;
	log-facility local7;
	EOF

	if [ "$DNS_SERVER_TYPE" = "local" ]; then
		dhcp_reverse_zone="$(reverse_zone_name "$LAN_V4_NET")."
		dhcp_subnet_mask="$(netmask_from_prefix "${LAN_V4_NET#*/}")"
		cat >>/etc/dhcp/dhcpd.conf <<-EOF
	key "dhcp-key" { algorithm hmac-sha512; secret "$DHCP_KEY"; };
	
	option domain-name "${LAN_DOMAIN}";
	option domain-name-servers ${dhcp_v4_dns_servers};
	
	ddns-update-style interim;
	ddns-updates on;
	ddns-domainname "${LAN_DOMAIN}.";
	ddns-rev-domainname "in-addr.arpa.";
	
	zone ${LAN_DOMAIN}. {
	  primary ${LAN_V4_IP};
	  key "dhcp-key";
	}
	
	zone ${dhcp_reverse_zone} {
		  primary ${LAN_V4_IP};
	  key "dhcp-key";
	}
		EOF
	else
		cat >>/etc/dhcp/dhcpd.conf <<-EOF
	option domain-name "${LAN_DOMAIN}";
	option domain-name-servers ${dhcp_v4_dns_servers};
		EOF
	fi

	cat >>/etc/dhcp/dhcpd.conf <<-EOF
	subnet $(echo "$LAN_V4_NET" | cut -d/ -f1) netmask $(netmask_from_prefix "${LAN_V4_NET#*/}") {
	  range ${DHCP_V4_START} ${DHCP_V4_END};
	  option routers ${LAN_V4_IP};
	  option subnet-mask ${dhcp_subnet_mask:-$(netmask_from_prefix "${LAN_V4_NET#*/}")};
	  option broadcast-address ${LAN_V4_BRD};
	}
	EOF
	
	if [ "$RA_SERVER_TYPE" = "disabled" ]; then
		: >/etc/dhcp/dhcpd6.conf
	else
		cat > /etc/dhcp/dhcpd6.conf <<-EOF
	authoritative;
	default-lease-time 3600;
	max-lease-time 86400;
	log-facility local7;

	$( [ -n "$dhcp_v6_dns_server" ] && printf 'option dhcp6.name-servers %s;\n' "$dhcp_v6_dns_server" )
	option dhcp6.domain-search "${LAN_DOMAIN}";
	
	subnet6 ${LAN_V6_PREFIX} {
	  range6 ${LAN_V6_RANGE_LOW} ${LAN_V6_RANGE_HIGH};
	}
		EOF
	fi
	
	touch /var/lib/dhcp/dhcpd.leases
	touch /var/lib/dhcp/dhcpd6.leases
	
	dhcpd -t -cf /etc/dhcp/dhcpd.conf >/dev/null 2>&1 || log_fatal "Invalid DHCPv4 configuration"
	
	unmask_service_if_needed isc-dhcp-server
	systemctl enable isc-dhcp-server >/dev/null 2>&1 || true
	systemctl restart isc-dhcp-server || log_fatal "Failed to restart isc-dhcp-server"
	
	log_success "DHCP configured"
}

################################################################################
# RADVD CONFIGURATION
################################################################################

configure_radvd() {
	if [ "$RA_SERVER_TYPE" = "disabled" ]; then
		log_info "IPv6 Router Advertisement disabled; stopping radvd if present"
		systemctl disable --now radvd >/dev/null 2>&1 || true
		return 0
	fi

	log_info "Configuring IPv6 Router Advertisement..."
	
	backup_file /etc/radvd.conf
	
	cat > /etc/radvd.conf <<-EOF
	interface $LAN_BR {
	  AdvSendAdvert on;
	  MaxRtrAdvInterval 30;
	  AdvManagedFlag off;
	  AdvOtherConfigFlag on;
	  
	  prefix ${LAN_V6_PREFIX} {
	    AdvOnLink on;
	    AdvAutonomous on;
	  };
	  
	  RDNSS ${LAN_V6_ROUTER_IP} { };
	};
	EOF
	
	radvd -C /etc/radvd.conf -n -c >/dev/null 2>&1 || log_warn "radvd config validation failed"
	
	unmask_service_if_needed radvd
	systemctl enable radvd >/dev/null 2>&1 || true
	systemctl restart radvd || log_fatal "Failed to restart radvd"
	
	log_success "IPv6 RA configured"
}

################################################################################
# POSTFIX CONFIGURATION
################################################################################

configure_postfix() {
	if ! is_enabled "$CONFIGURE_POSTFIX"; then
		return
	fi

	if [ "$POSTFIX_SERVER_TYPE" = "forward" ]; then
		if reachable_host "$POSTFIX_FORWARD_HOST"; then
			log_info "Postfix forward mode active; disabling local Postfix and forwarding mail ports"
			systemctl disable --now postfix >/dev/null 2>&1 || true
			add_summary "Forwarding mail service ports to ${POSTFIX_FORWARD_HOST}"
			return 0
		fi
		log_warn "POSTFIX_FORWARD_HOST unavailable; falling back to local Postfix behavior"
		POSTFIX_SERVER_TYPE="local"
	fi
	
	log_info "Configuring Postfix (${POSTFIX_SERVER_TYPE})..."
	
	if ! command_exists postfix; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix >/dev/null 2>&1
	fi
	
	backup_file /etc/postfix/main.cf
	backup_file /etc/aliases
	
	postconf -e "myhostname = ${POSTFIX_MYHOSTNAME}"
	postconf -e "mydomain = ${POSTFIX_MYDOMAIN}"
	postconf -e "myorigin = \$mydomain"
	postconf -e "inet_interfaces = all"
	postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
	postconf -e "mynetworks = 127.0.0.0/8, ${LAN_V4_NET}, [::1]/128, ${LAN_V6_PREFIX}"
	postconf -e "smtp_tls_security_level = may"
	postconf -e "smtp_sasl_auth_enable = no"
	postconf -e "smtp_sasl_password_maps ="
	postconf -e "smtp_sasl_security_options = noanonymous"

	case "$POSTFIX_SERVER_TYPE" in
	relay)
		postconf -e "relayhost = [${POSTFIX_SMTP_RELAY}]:${POSTFIX_SMTP_PORT}"
		if is_enabled "$POSTFIX_RELAY_TLS"; then
			postconf -e "smtp_tls_security_level = encrypt"
			postconf -e "smtp_tls_loglevel = 1"
		else
			postconf -e "smtp_tls_security_level = may"
		fi
		if [ -n "$POSTFIX_RELAY_USERNAME" ] && [ -n "$POSTFIX_RELAY_PASSWORD" ]; then
			cat >/etc/postfix/sasl_passwd <<-EOF
				[${POSTFIX_SMTP_RELAY}]:${POSTFIX_SMTP_PORT} ${POSTFIX_RELAY_USERNAME}:${POSTFIX_RELAY_PASSWORD}
			EOF
			chmod 600 /etc/postfix/sasl_passwd
			postmap /etc/postfix/sasl_passwd
			postconf -e "smtp_sasl_auth_enable = yes"
			postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
			postconf -e "smtp_sasl_security_options = noanonymous"
		fi
		;;
	satellite)
		postconf -e "relayhost = [${POSTFIX_SMTP_RELAY}]:${POSTFIX_SMTP_PORT}"
		postconf -e "inet_interfaces = loopback-only"
		postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
		if is_enabled "$POSTFIX_RELAY_TLS"; then
			postconf -e "smtp_tls_security_level = encrypt"
			postconf -e "smtp_tls_loglevel = 1"
		else
			postconf -e "smtp_tls_security_level = may"
		fi
		if [ -n "$POSTFIX_RELAY_USERNAME" ] && [ -n "$POSTFIX_RELAY_PASSWORD" ]; then
			cat >/etc/postfix/sasl_passwd <<-EOF
				[${POSTFIX_SMTP_RELAY}]:${POSTFIX_SMTP_PORT} ${POSTFIX_RELAY_USERNAME}:${POSTFIX_RELAY_PASSWORD}
			EOF
			chmod 600 /etc/postfix/sasl_passwd
			postmap /etc/postfix/sasl_passwd
			postconf -e "smtp_sasl_auth_enable = yes"
			postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
			postconf -e "smtp_sasl_security_options = noanonymous"
		fi
		;;
	internet)
		postconf -e "relayhost = "
		postconf -e "inet_interfaces = all"
		;;
	local)
		postconf -e "relayhost = "
		postconf -e "inet_interfaces = loopback-only"
		;;
	esac

	cat >/etc/postfix/sender_canonical <<-EOF
		/.*/ ${POSTFIX_FROM_EMAIL}
	EOF
	postconf -e "sender_canonical_maps = regexp:/etc/postfix/sender_canonical"
	
	if [ ! -f /etc/aliases ] || ! grep -q "^root:" /etc/aliases; then
		echo "root: ${POSTFIX_ROOT_FORWARD}" >> /etc/aliases
	fi
	newaliases >/dev/null 2>&1
	
	unmask_service_if_needed postfix
	systemctl enable postfix >/dev/null 2>&1 || true
	systemctl restart postfix || log_fatal "Failed to restart postfix"
	
	log_success "Postfix configured"
	if [ "$POSTFIX_SERVER_TYPE" = "internet" ] || is_enabled "$POSTFIX_WAN_ENABLE"; then
		add_summary "Enabled WAN mail exposure for ports 25, 465, 587"
	fi
	if [ "$POSTFIX_SERVER_TYPE" = "relay" ] || [ "$POSTFIX_SERVER_TYPE" = "satellite" ]; then
		add_summary "Configured Postfix relay via ${POSTFIX_SMTP_RELAY}:${POSTFIX_SMTP_PORT}"
	fi
}

################################################################################
# NGINX CONFIGURATION
################################################################################

write_nginx_mime_types() {
	cat >/etc/nginx/mime.types <<'EOF'
types {
    text/html                                        html htm shtml;
    text/css                                         css;
    text/xml                                         xml;
    image/gif                                        gif;
    image/jpeg                                       jpeg jpg;
    application/javascript                           js;
    application/atom+xml                             atom;
    application/rss+xml                              rss;

    text/mathml                                      mml;
    text/plain                                       txt;
    text/vnd.sun.j2me.app-descriptor                 jad;
    text/vnd.wap.wml                                 wml;
    text/x-component                                 htc;

    image/avif                                       avif;
    image/png                                        png;
    image/svg+xml                                    svg svgz;
    image/tiff                                       tif tiff;
    image/vnd.wap.wbmp                               wbmp;
    image/webp                                       webp;
    image/x-icon                                     ico;
    image/x-jng                                      jng;
    image/x-ms-bmp                                   bmp;

    font/woff                                        woff;
    font/woff2                                       woff2;

    application/java-archive                         jar war ear;
    application/json                                 json;
    application/mac-binhex40                         hqx;
    application/msword                               doc;
    application/pdf                                  pdf;
    application/postscript                           ps eps ai;
    application/rtf                                  rtf;
    application/vnd.apple.mpegurl                    m3u8;
    application/vnd.google-earth.kml+xml             kml;
    application/vnd.google-earth.kmz                 kmz;
    application/vnd.ms-excel                         xls;
    application/vnd.ms-fontobject                    eot;
    application/vnd.ms-powerpoint                    ppt;
    application/vnd.oasis.opendocument.graphics      odg;
    application/vnd.oasis.opendocument.presentation  odp;
    application/vnd.oasis.opendocument.spreadsheet   ods;
    application/vnd.oasis.opendocument.text          odt;
    application/vnd.openxmlformats-officedocument.presentationml.presentation
                                                     pptx;
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
                                                     xlsx;
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
                                                     docx;
    application/vnd.wap.wmlc                         wmlc;
    application/wasm                                 wasm;
    application/x-7z-compressed                      7z;
    application/x-cocoa                              cco;
    application/x-java-archive-diff                  jardiff;
    application/x-java-jnlp-file                     jnlp;
    application/x-makeself                           run;
    application/x-perl                               pl pm;
    application/x-pilot                              prc pdb;
    application/x-rar-compressed                     rar;
    application/x-redhat-package-manager             rpm;
    application/x-sea                                sea;
    application/x-shockwave-flash                    swf;
    application/x-stuffit                            sit;
    application/x-tcl                                tcl tk;
    application/x-x509-ca-cert                       der pem crt;
    application/x-xpinstall                          xpi;
    application/xhtml+xml                            xhtml;
    application/xspf+xml                             xspf;
    application/zip                                  zip;

    application/octet-stream                         bin exe dll;
    application/octet-stream                         deb;
    application/octet-stream                         dmg;
    application/octet-stream                         iso img;
    application/octet-stream                         msi msp msm;

    audio/midi                                       mid midi kar;
    audio/mpeg                                       mp3;
    audio/ogg                                        ogg;
    audio/x-m4a                                      m4a;
    audio/x-realaudio                                ra;

    video/3gpp                                       3gpp 3gp;
    video/mp2t                                       ts;
    video/mp4                                        mp4;
    video/mpeg                                       mpeg mpg;
    video/quicktime                                  mov;
    video/webm                                       webm;
    video/x-flv                                      flv;
    video/x-m4v                                      m4v;
    video/x-mng                                      mng;
    video/x-ms-asf                                   asx asf;
    video/x-ms-wmv                                   wmv;
    video/x-msvideo                                  avi;
}
EOF
}

configure_nginx() {
	log_info "Configuring nginx..."

	local fqdn nginx_ssl_cert nginx_ssl_key vhost_file mime_tmp
	fqdn="$(get_host_fqdn)"
	nginx_ssl_cert="/etc/pve/local/pve-ssl.pem"
	nginx_ssl_key="/etc/pve/local/pve-ssl.key"
	vhost_file="/etc/nginx/vhosts.d/${fqdn}.conf"
	mime_tmp="/tmp/mime.types.$$"

	command_exists nginx || log_fatal "nginx is not installed"
	[ -f "$nginx_ssl_cert" ] || log_fatal "Missing Proxmox SSL certificate: $nginx_ssl_cert"
	[ -f "$nginx_ssl_key" ] || log_fatal "Missing Proxmox SSL key: $nginx_ssl_key"

	if [ -d /etc/nginx ]; then
		mkdir -p "${BACKUP_DIR}/etc"
		cp -a /etc/nginx "${BACKUP_DIR}/etc/" 2>/dev/null || true
	fi

	mkdir -p /etc/nginx
	if [ ! -f /etc/nginx/mime.types ]; then
		write_nginx_mime_types
	fi
	backup_file /etc/nginx/mime.types
	mv -f /etc/nginx/mime.types "$mime_tmp"
	rm -rf /etc/nginx/*
	mv -f "$mime_tmp" /etc/nginx/mime.types
	[ -f /etc/nginx/mime.types ] || log_fatal "Unable to restore /etc/nginx/mime.types"

	mkdir -p /etc/nginx/conf.d /etc/nginx/global.d /etc/nginx/services.d /etc/nginx/vhosts.d

	cat >/etc/nginx/conf.d/log_format.conf <<-'EOF'
		log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
		                  '$status $body_bytes_sent "$http_referer" '
		                  '"$http_user_agent" "$http_x_forwarded_for"';
	EOF

	cat >/etc/nginx/conf.d/default.conf <<-'EOF'
		map $http_upgrade $connection_upgrade { default upgrade; '' close; }
		upstream pveproxy { server 127.0.0.1:8006 fail_timeout=0; }
	EOF

	cat >/etc/nginx/nginx.conf <<-'EOF'
		# nginx server settings
		user              www-data;
		worker_processes  auto;

		pid               /run/nginx.pid;
		error_log         /var/log/nginx/error.log warn;

		events {
		    worker_connections  1024;
		}

		http {
		    sendfile           on;
		    keepalive_timeout  65;
		    default_type       text/html;
		    include            /etc/nginx/mime.types;
		    include            /etc/nginx/conf.d/*.conf;
		    access_log         /var/log/nginx/access.log  main;

		    server {
		        listen       80 default_server;
		        listen       [::]:80 default_server;
		        server_name  _;
		        return       301 https://$host$request_uri;
		        include      /etc/nginx/global.d/*.conf;
		    }
		    include /etc/nginx/vhosts.d/*.conf;
		}

		include /etc/nginx/services.d/*.conf;
	EOF

	cat >"$vhost_file" <<-EOF
		server {
		  server_name                      ${fqdn};
		  listen 443                       ssl default_server;
		  listen [::]:443                  ssl default_server;
		  keepalive_timeout                75 75;
		  access_log                       /var/log/nginx/access.log;
		  error_log                        /var/log/nginx/error.log info;
		  ssl_prefer_server_ciphers        off;
		  ssl_protocols                    TLSv1.2 TLSv1.3;
		  ssl_certificate                  ${nginx_ssl_cert};
		  ssl_certificate_key              ${nginx_ssl_key};
		  ssl_ciphers                      ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

		  location / {
		    client_max_body_size           0;
		    send_timeout                   3600;
		    proxy_connect_timeout          3600;
		    proxy_send_timeout             3600;
		    proxy_read_timeout             3600;
		    proxy_http_version             1.1;
		    proxy_buffering                off;
		    proxy_request_buffering        off;
		    proxy_ssl_verify               off;
		    proxy_set_header               Host \$host:\$server_port;
		    proxy_set_header               X-Real-IP \$remote_addr;
		    proxy_set_header               X-Forwarded-For \$proxy_add_x_forwarded_for;
		    proxy_set_header               X-Forwarded-Proto \$scheme;
		    proxy_set_header               Upgrade \$http_upgrade;
		    proxy_set_header               Connection \$connection_upgrade;
		    proxy_redirect                 https://127.0.0.1:8006/ https://\$host/;
		    proxy_pass                     https://pveproxy;
		  }
		  include /etc/nginx/global.d/*.conf;
		}
	EOF

	nginx -t >/dev/null 2>&1 || log_fatal "Invalid nginx configuration"
	unmask_service_if_needed nginx
	systemctl enable nginx >/dev/null 2>&1 || true
	systemctl restart nginx || log_fatal "Failed to restart nginx"

	log_success "nginx configured"
	add_summary "Configured nginx reverse proxy for ${fqdn}"
}

################################################################################
# SDN CONFIGURATION
################################################################################

configure_sdn() {
	log_info "Configuring Proxmox SDN..."
	
	mkdir -p /etc/pve/sdn
	
	if [ ! -f /etc/pve/sdn/sdn.cfg ]; then
		cat > /etc/pve/sdn/sdn.cfg <<-EOF
		zone: localnet
		        type simple
		        bridge ${LAN_BR}
		        ipam pve
		
		vnet: vnet100
		        zone localnet
		        tag 100
		
		vnet: vnet200
		        zone localnet
		        tag 200
		
		vnet: vnet300
		        zone localnet
		        tag 300
		EOF
	fi
	
	if [ ! -f /etc/pve/sdn/ipam.cfg ]; then
		cat > /etc/pve/sdn/ipam.cfg <<-EOF
		pve: local
		EOF
	fi
	
	pvesh create /cluster/sdn >/dev/null 2>&1 || true
	
	log_success "SDN configured"
}

configure_vlan_readiness() {
	log_info "Configuring VLAN readiness..."
	modprobe 8021q 2>/dev/null || true
	mkdir -p /etc/modules-load.d
	if ! grep -q "^8021q$" /etc/modules-load.d/proxmox-bootstrap.conf 2>/dev/null; then
		echo "8021q" >>/etc/modules-load.d/proxmox-bootstrap.conf
	fi
	log_success "VLAN readiness configured"
}

################################################################################
# VM/CONTAINER DEFAULTS
################################################################################

replace_bridge_in_config_value() {
	local value="$1"
	local bridge="$2"
	echo "$value" | sed -E "s/(^|,)bridge=[^,]*/\\1bridge=${bridge}/"
}

configure_vm_defaults() {
	log_info "Configuring VM/Container defaults..."

	local vm_updates=0 ct_updates=0 spice_updates=0
	if [ -d /etc/pve/qemu-server ]; then
		for conf in /etc/pve/qemu-server/*.conf; do
			[ -f "$conf" ] || continue
			vmid=$(basename "$conf" .conf)
			local net_count net_line net_value updated_value
			net_count="$(grep -cE '^net[0-9]+:' "$conf" 2>/dev/null || true)"
			if [ "$net_count" -eq 1 ]; then
				net_line="$(grep -E '^net[0-9]+:' "$conf" | head -n1)"
				net_value="${net_line#*: }"
				if echo "$net_value" | grep -q 'bridge=' && ! echo "$net_value" | grep -q "bridge=${LAN_BR}"; then
					updated_value="$(replace_bridge_in_config_value "$net_value" "$LAN_BR")"
					qm set "$vmid" --net0 "$updated_value" >/dev/null 2>&1 && vm_updates=$((vm_updates + 1)) || true
				fi
			fi

			if ! grep -q '^vga:' "$conf" 2>/dev/null && ! grep -q '^args:' "$conf" 2>/dev/null; then
				qm set "$vmid" --vga qxl >/dev/null 2>&1 && spice_updates=$((spice_updates + 1)) || true
			fi
		done
	fi
	
	if [ -d /etc/pve/lxc ]; then
		for conf in /etc/pve/lxc/*.conf; do
			[ -f "$conf" ] || continue
			ctid=$(basename "$conf" .conf)
			local net_count net_line net_value updated_value
			net_count="$(grep -cE '^net[0-9]+:' "$conf" 2>/dev/null || true)"
			if [ "$net_count" -eq 1 ]; then
				net_line="$(grep -E '^net[0-9]+:' "$conf" | head -n1)"
				net_value="${net_line#*: }"
				if echo "$net_value" | grep -q 'bridge=' && ! echo "$net_value" | grep -q "bridge=${LAN_BR}"; then
					updated_value="$(replace_bridge_in_config_value "$net_value" "$LAN_BR")"
					pct set "$ctid" --net0 "$updated_value" >/dev/null 2>&1 && ct_updates=$((ct_updates + 1)) || true
				fi
			fi
		done
	fi
	
	log_success "VM defaults configured"
	add_summary "Updated guest defaults: ${vm_updates} VM NICs, ${ct_updates} LXC NICs, ${spice_updates} VM display defaults"
}

################################################################################
# TEMPLATE DOWNLOADS
################################################################################

download_templates() {
	if ! is_enabled "$DOWNLOAD_TEMPLATES"; then
		return
	fi
	
	log_info "Downloading LXC templates..."
	if ! command_exists pveam; then
		log_warn "pveam not available, skipping template downloads"
		return 0
	fi
	
	pveam update >/dev/null 2>&1 || true

	local template
	for template in debian-12-standard ubuntu-24.04-standard rockylinux-9-default almalinux-9-default; do
		download_template_item "$template" &
	done

	wait
	log_success "Template download complete"
}

################################################################################
# ISO DOWNLOADS
################################################################################

download_isos() {
	if ! is_enabled "$DOWNLOAD_ISOS"; then
		return
	fi
	
	log_info "Downloading ISOs..."
	
	ISO_DIR="/var/lib/vz/template/iso"
	mkdir -p "$ISO_DIR"
	cd "$ISO_DIR"

	local debian_base="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
	local ubuntu_base="https://releases.ubuntu.com"
	local pfsense_base="https://atxfiles.netgate.com/mirror/downloads"
	local proxmox_base="https://enterprise.proxmox.com/iso"
	local ubuntu_release alma_major rocky_major alma_base rocky_base xcpng_url xcpng_file
	local alma_index rocky_index xcpng_page

	DEBIAN_ISO=$(curl -fsSL "${debian_base}/" 2>/dev/null | grep -oE 'debian-[0-9.]+-amd64-netinst.iso' | head -1 || true)
	ubuntu_release=$(curl -fsSL "${ubuntu_base}/" 2>/dev/null | grep -oE '[0-9]{2}\.04(\.[0-9]+)?' | sort -Vr | head -1 || true)
	UBUNTU_ISO=""
	if [ -n "$ubuntu_release" ]; then
		UBUNTU_ISO=$(curl -fsSL "${ubuntu_base}/${ubuntu_release}/" 2>/dev/null | grep -oE "ubuntu-${ubuntu_release}-live-server-amd64.iso" | head -1 || true)
	fi
	PROXMOX_ISO=$(curl -fsSL https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso 2>/dev/null | grep -oE 'proxmox-ve_[0-9.]+-[0-9]+.iso' | head -1 || true)
	PFSENSE_ISO=$(curl -fsSL "${pfsense_base}/" 2>/dev/null | grep -oE 'pfSense-CE-[0-9.]+-RELEASE-amd64.iso.gz' | sort -Vu | tail -1 || true)
	alma_index="$(curl -fsSL https://repo.almalinux.org/almalinux/ 2>/dev/null || true)"
	alma_major="$(printf '%s' "$alma_index" | grep -oE 'href="[0-9]+/"' | grep -oE '[0-9]+' | sort -V | tail -1 || true)"
	if [ -n "$alma_major" ]; then
		alma_base="https://repo.almalinux.org/almalinux/${alma_major}/isos/x86_64"
		ALMA_ISO="$(curl -fsSL "${alma_base}/" 2>/dev/null | grep -oE "AlmaLinux-${alma_major}-latest-x86_64-minimal.iso|AlmaLinux-[0-9.]+-x86_64-minimal.iso" | head -1 || true)"
	fi
	rocky_index="$(curl -fsSL https://download.rockylinux.org/pub/rocky/ 2>/dev/null || true)"
	rocky_major="$(printf '%s' "$rocky_index" | grep -oE 'href="[0-9]+/"' | grep -oE '[0-9]+' | sort -V | tail -1 || true)"
	if [ -n "$rocky_major" ]; then
		rocky_base="https://download.rockylinux.org/pub/rocky/${rocky_major}/isos/x86_64"
		ROCKY_ISO="$(curl -fsSL "${rocky_base}/" 2>/dev/null | grep -oE "Rocky-${rocky_major}-latest-x86_64-minimal.iso|Rocky-[0-9.]+-x86_64-minimal.iso" | head -1 || true)"
	fi
	xcpng_page="$(curl -fsSL https://xcp-ng.org/#easy-to-install 2>/dev/null || true)"
	xcpng_url="$(printf '%s' "$xcpng_page" | grep -oE 'https://mirrors\.xcp-ng\.org/isos/[0-9.]+/xcp-ng-[0-9.]+-[0-9.]+(\.[0-9]+)?\.iso\?https=1' | grep -v netinstall | head -1 || true)"
	xcpng_file="${xcpng_url##*/}"
	XCPNG_ISO="${xcpng_file%%\?*}"

	download_iso_file "$DEBIAN_ISO" "${debian_base}/${DEBIAN_ISO}" &
	download_iso_file "$UBUNTU_ISO" "${ubuntu_base}/${ubuntu_release}/${UBUNTU_ISO}" &
	download_iso_file "$PROXMOX_ISO" "${proxmox_base}/${PROXMOX_ISO}" &
	download_iso_file "$ALMA_ISO" "${alma_base}/${ALMA_ISO}" &
	download_iso_file "$ROCKY_ISO" "${rocky_base}/${ROCKY_ISO}" &
	download_iso_file "$XCPNG_ISO" "$xcpng_url" &

	if [ -n "$PFSENSE_ISO" ] && [ ! -f "${PFSENSE_ISO%.gz}" ]; then
		log_info "Downloading $PFSENSE_ISO..."
		{
			local pfsense_tmp
			pfsense_tmp="$(mktemp --suffix=.iso.gz)"
			if ! curl -fsSL "${pfsense_base}/${PFSENSE_ISO}" -o "$pfsense_tmp" 2>/dev/null ||
				! gunzip -c "$pfsense_tmp" >"${PFSENSE_ISO%.gz}" 2>/dev/null; then
				rm -f "${PFSENSE_ISO%.gz}"
				rm -f "$pfsense_tmp"
				log_warn "Failed to download $PFSENSE_ISO"
			else
				rm -f "$pfsense_tmp"
				mark_task_done "iso:${PFSENSE_ISO%.gz}"
			fi
		} &
	elif [ -n "$PFSENSE_ISO" ] && [ -f "${PFSENSE_ISO%.gz}" ]; then
		mark_task_done "iso:${PFSENSE_ISO%.gz}"
	fi
	
	wait
	log_success "ISO download complete"
}

download_template_item() {
	local template_pattern="$1"
	local latest cache_file task_name

	latest="$(pveam available | awk -v pattern="$template_pattern" '$2 ~ pattern { latest = $2 } END { print latest }')"
	if [ -z "$latest" ]; then
		log_warn "No template match found for ${template_pattern}"
		return 0
	fi

	cache_file="/var/lib/vz/template/cache/${latest}"
	task_name="template:${latest}"
	if [ -f "$cache_file" ]; then
		mark_task_done "$task_name"
		return 0
	fi

	log_info "Downloading ${latest}..."
	if pveam download local "$latest" >/dev/null 2>&1; then
		mark_task_done "$task_name"
	else
		log_warn "Failed to download template ${latest}"
	fi
}

download_iso_file() {
	local filename="$1"
	local url="$2"
	local task_name

	[ -n "$filename" ] || return 0
	[ -n "$url" ] || return 0
	task_name="iso:${filename}"
	if [ -f "$filename" ]; then
		mark_task_done "$task_name"
		return 0
	fi

	log_info "Downloading $filename..."
	curl -fsSL "$url" -o "$filename" 2>/dev/null || {
		rm -f "$filename"
		log_warn "Failed to download $filename"
		return 0
	}
	mark_task_done "$task_name"
}

download_optional_tool() {
	local name="$1"
	local url="$2"
	local target="$3"

	mkdir -p "$OPTIONAL_TOOLS_DIR"
	log_info "Downloading ${name}..."
	if curl -fsSL "$url" -o "$target"; then
		chmod 700 "$target"
		log_info "${name} saved to ${target}"
		log_info "Run manually when ready: bash ${target}"
	else
		log_warn "Failed to download ${name}"
	fi
}

download_proxmenux_tool() {
	download_optional_tool \
		"ProxMenux installer" \
		"$PROXMENUX_INSTALLER_URL" \
		"${OPTIONAL_TOOLS_DIR}/install_proxmenux.sh"
}

download_community_post_install_tool() {
	download_optional_tool \
		"community Proxmox post-install script" \
		"$COMMUNITY_POST_INSTALL_URL" \
		"${OPTIONAL_TOOLS_DIR}/post-pve-install.sh"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
	parse_args "$@"
	check_root

	mkdir -p "$LOG_DIR" "$BACKUP_DIR"
	warn_if_backup_parent_unmounted

	log_info "Proxmox Bootstrap Script v${SCRIPT_VERSION}"
	log_info "Log file: $LOG_FILE"

	load_config_file
	detect_pve_version
	configure_node_name
	detect_network_interfaces
	check_ip_conflicts
	run_task network configure_network
	run_task repositories configure_repositories
	if is_enabled "$AUTO_DIST_UPGRADE"; then
		run_task system_upgrade upgrade_system
	fi
	run_task packages install_packages
	configure_apparmor
	run_task kernel_policy configure_kernel_policy
	run_task sysctl configure_sysctl
	run_task vlan configure_vlan_readiness
	run_task ssh configure_ssh
	run_task fail2ban configure_fail2ban
	run_task subscription_nag configure_subscription_nag
	run_task firewall configure_nftables
	run_task bind configure_bind9
	run_task dhcp configure_dhcp
	run_task radvd configure_radvd
	if is_enabled "$CONFIGURE_POSTFIX"; then
		run_task postfix configure_postfix
	fi
	run_task tls_certs configure_letsencrypt_pve_cert_hook
	run_task nginx configure_nginx
	if is_enabled "$CONFIGURE_SDN"; then
		run_task sdn configure_sdn
	fi
	run_task vm_defaults configure_vm_defaults
	if is_enabled "$DOWNLOAD_TEMPLATES"; then
		download_templates
	fi
	if is_enabled "$DOWNLOAD_ISOS"; then
		download_isos
	fi
	if is_enabled "$RUN_PROXMENUX"; then
		run_task proxmenux_tool download_proxmenux_tool
	fi
	if is_enabled "$RUN_POST_INSTALL"; then
		run_task community_post_install_tool download_community_post_install_tool
	fi

	log_success "Bootstrap complete!"
	log_info ""
	print_summary
	log_info ""
	log_info "Next steps:"
	if [ -n "$WAN_V4_IP" ]; then
		log_info "  - Access Proxmox via nginx: https://$(get_host_fqdn)"
		log_info "  - Access Proxmox UI: https://${WAN_V4_IP}:8006"
	else
		log_info "  - Access Proxmox via nginx: https://$(get_host_fqdn)"
		log_info "  - Access Proxmox UI: https://<wan-ip>:8006"
	fi
	log_info "  - DNS Server: ${LAN_V4_IP}"
	log_info "  - DHCP Range: ${DHCP_V4_START} - ${DHCP_V4_END}"
	log_info "  - Log file: $LOG_FILE"
	log_info "  - Reboot recommended if kernel or core packages changed"
}

################################################################################
# SCRIPT ENTRY POINT
################################################################################

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
fi
