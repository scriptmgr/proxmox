# Proxmox VE Bootstrap Script

Idempotent Proxmox VE bootstrap for turning a fresh host into a routed/NAT LAN environment for VMs and containers.

## Overview

This project provides a single non-interactive bootstrap script for Proxmox VE that configures:

- WAN/LAN bridge layout
- IPv4 and IPv6 LAN routing
- nftables firewalling and NAT
- BIND9 DNS with DHCP DDNS integration
- ISC DHCP and IPv6 router advertisements
- Postfix mail handling
- Nginx reverse proxy for the Proxmox UI
- Proxmox repository setup and basic hardening
- VLAN readiness and optional SDN preparation
- VM/LXC defaults that steer guests to the LAN bridge

The project spec lives in [`AI.md`](AI.md). When this README and the implementation drift, `AI.md` is the source of truth.

## Supported Versions

- Compatibility target: Proxmox VE 7.x, 8.x, 9.x
- Active test target: `rtedpro/proxmox:9.1.9`

## Quick Start

```bash
curl -qLSsf https://github.com/scriptmgr/proxmox/raw/refs/heads/main/install.sh | bash
```

Or:

```bash
wget https://github.com/scriptmgr/proxmox/raw/refs/heads/main/install.sh
chmod +x install.sh
./install.sh
```

## CLI

```text
--help                 Show usage and exit 0
--init                 Write /etc/proxmox-bootstrap.conf and exit 0
--status               Show completed state-tracked tasks and exit 0
--clear-state [task]   Clear all task state or one named task and exit 0
--reset                Remove bootstrap-managed configuration and state
--force                Re-run tasks even when state says complete
```

Unknown options exit with status `2`.

## Defaults

The script is intended to work on first run with no required user config.

### Network Defaults

- WAN bridge defaults to `vmbr0`
- LAN bridge defaults to `vmbr1`
- Default LAN subnet starts at `192.168.251.1/24`
- Default LAN IPv6 ULA follows the chosen IPv4 third octet, for example `fd00:251::/64`
- Default DHCP range for `/24` LANs is `.100` through `.200`
- `FWD1=1.1.1.1`, `FWD2=8.8.8.8`, `FWD3=4.4.4.4`

### Auto-Detection

- NICs default to auto-detection
- LAN domain defaults to:
  1. `hostname -d`
  2. `$(hostname -s).home`
  3. `pve.home`
- On single-NIC hosts, the script keeps WAN intact and creates a dummy-backed LAN bridge using `pvedummy{num}`
- When LAN is dummy-backed, the script also adds a separate router-lab pair using the next indices: `pverouter{num+1}` on `vmbr{num+1}`
- If the preferred LAN bridge already exists and is unsuitable, the script uses the next free `vmbr{num}`

### Optional Features

Disabled by default unless explicitly enabled:

- ISO downloads
- LXC template downloads
- ProxMenux download helper
- Community post-install script download helper
- SDN object creation

### Enabled by Default

- Proxmox no-subscription repository
- Subscription nag removal
- Postfix
- VLAN readiness via `8021q`

## Configuration

The script loads configuration in this precedence order, highest to lowest:

1. Runtime environment variables
2. `./.env`
3. `/etc/proxmox-bootstrap.conf`
4. Built-in defaults

`--init` writes the effective configuration after applying that precedence.

Useful automation controls:

```bash
AUTO_DIST_UPGRADE="yes"        # apply non-interactive dist-upgrade after repo setup
PIN_NEWEST_PVE_KERNEL="yes"    # pin the newest installed Proxmox kernel
PVE_KERNEL_KEEP_COUNT="2"      # keep two installed Proxmox kernel versions total
```

## Package Installation

Package installation is mode-driven:

- Always install the base shell, networking, sync, and crypto utilities the bootstrap depends on
- Always install core networking packages such as `nftables`, `bridge-utils`, and `ifupdown2`
- Always install SSH hardening packages `fail2ban`, `apparmor`, and `apparmor-utils`
- Install local DNS, DHCP, and RA packages only when their effective service mode is local
- Install `isc-dhcp-relay` only when DHCP relay mode is active
- Install `postfix` and `mailutils` only when Postfix support remains enabled
- Install and configure `nginx` as a reverse proxy for the Proxmox UI

### Example

```bash
export LAN_V4="10.10.20.1/24"
export LAN_DOMAIN="lab.home"
export DHCP_V4_START="10.10.20.100"
export DHCP_V4_END="10.10.20.200"

./install.sh
```

### Initialize a Config File

```bash
./install.sh --init
chmod 600 /etc/proxmox-bootstrap.conf
```

### `.env` Support

If `./.env` exists in the current working directory, it is loaded automatically and can override values from `/etc/proxmox-bootstrap.conf`.

## Network Model

Target bridge model:

- `vmbr0`: WAN bridge
- `vmbr1`: preferred LAN bridge
- Guests should use the LAN bridge, not the WAN bridge
- When LAN is dummy-backed, the original LAN pair stays on `pvedummy{num}` + `vmbr{num+1}`
- A separate router-lab pair is added on the next indices so pfSense and other router/firewall guests can own a dedicated VLAN-aware segment

Behavior by host type:

- **1 physical NIC**: preserve existing WAN behavior and add a dummy-backed LAN bridge plus a separate router-lab pair
- **2 physical NICs**: preserve WAN and use the other NIC for LAN by default
- **More than 2 physical NICs**: preserve WAN and default LAN to dummy-backed mode unless `LAN_NIC` is explicitly set

Additional rules:

- Existing WAN settings must not be changed unless explicit WAN variables are supplied
- Unused physical NICs are left untouched
- Network config should be additive and preserve existing working Proxmox networking where possible
- The router-lab bridge is created VLAN-aware so router/firewall guests can trunk tagged networks to downstream guests
- The resolved LAN bridge and LAN NIC are persisted so reruns remain stable

## LAN Addressing

- The script checks for subnet conflicts and increments the third octet until it finds a free LAN subnet
- IPv6 ULA defaults follow the chosen IPv4 LAN subnet
- Derived DHCP ranges must stay inside the selected LAN subnet
- Reverse DNS generation supports arbitrary IPv4 prefixes, not just `/24`

## Services

### DNS

Default mode: `DNS_SERVER_TYPE=local`

Accepted values:

- `local`
- `forward`
- `disabled`

Behavior:

- `local` configures BIND9 on LAN and localhost
- `forward` disables local BIND9 and forwards DNS to a user-managed backend
- `disabled` leaves local DNS off
- If `forward` is selected but the backend is unset or unreachable, the script falls back to `local`

Split DNS controls:

- `DNS_SPLIT_ENABLE=yes|no`
- `DNS_WAN_ENABLE=yes|no`
- `DNS_WAN_ZONE`
- `DNS_WAN_RECORDS_FILE`
- `DNS_LAN_RECURSION=yes|no`
- `DNS_WAN_RECURSION=yes|no`

Default local DNS records include:

- `ns1`
- `gw`
- `{node-name}`
- `pve`

DHCP DDNS updates are limited to the LAN forward and reverse zones.

### DHCP

Default mode: `DHCP_SERVER_TYPE=local`

Accepted values:

- `local`
- `relay`
- `disabled`

Behavior:

- `local` configures ISC DHCP
- `relay` disables local ISC DHCP and relays to `DHCP_RELAY_HOST`
- `disabled` leaves local DHCP off
- If relay is selected but the backend is unset or unreachable, the script falls back to `local`
- If DHCP remains local while DNS is disabled, DHCP hands out the configured upstream IPv4 resolvers instead of advertising the Proxmox host as DNS
- If DHCP remains local while DNS is forwarded, IPv4 clients use the Proxmox host as the DNS relay endpoint but DHCPv6 does not advertise a nonexistent local IPv6 DNS service

### IPv6 RA

Default mode: `RA_SERVER_TYPE=local`

Accepted values:

- `local`
- `disabled`

Behavior:

- `local` configures `radvd`
- `disabled` leaves router advertisements off
- If RA is disabled while local DHCPv6 would otherwise be active, the script avoids inconsistent IPv6 behavior and prefers disabling local DHCPv6 unless explicitly configured otherwise

### Mail

Postfix is enabled by default.

Primary configuration surface:

- `POSTFIX_SERVER_TYPE=local|relay|satellite|internet|forward`
- `POSTFIX_SMTP_RELAY`
- `POSTFIX_SMTP_PORT`
- `POSTFIX_FROM_EMAIL`
- `POSTFIX_FROM_NAME`
- `POSTFIX_ROOT_FORWARD`
- `POSTFIX_MYHOSTNAME`
- `POSTFIX_MYDOMAIN`
- `POSTFIX_RELAY_TLS`
- `POSTFIX_RELAY_USERNAME`
- `POSTFIX_RELAY_PASSWORD`
- `POSTFIX_WAN_ENABLE=yes|no`
- `POSTFIX_FORWARD_HOST`
- `POSTFIX_FORWARD_PORTS`

Behavior:

- Invalid `POSTFIX_SERVER_TYPE` falls back safely to `relay` when a relay is configured, otherwise `local`
- SASL relay auth is supported when both relay username and password are set
- `POSTFIX_RELAY_TLS` is inferred from the relay port unless explicitly set
- WAN mail ports stay closed by default
- `POSTFIX_SERVER_TYPE=internet` opens WAN ports `25`, `465`, `587`
- `POSTFIX_SERVER_TYPE=forward` disables local Postfix only when `POSTFIX_FORWARD_HOST` is set and passes a quick reachability check
- In forward mode, WAN and LAN mail service ports are forwarded to the user-managed backend

Legacy variables such as `MAIL_RELAY_HOST`, `MAIL_RELAY_PORT`, and `ROOT_MAIL_FORWARD` may exist for compatibility, but `POSTFIX_*` is the intended config surface.

### Nginx

- `nginx` is configured as a reverse proxy in front of the Proxmox UI
- `/etc/nginx/*` is rebuilt during bootstrap while preserving `mime.types`
- The generated vhost lives at `/etc/nginx/vhosts.d/{fqdn}.conf`
- HTTP redirects to HTTPS and HTTPS proxies to `https://127.0.0.1:8006`
- The proxy uses the Proxmox node certificate files in `/etc/pve/local/pve-ssl.pem` and `/etc/pve/local/pve-ssl.key`
- If `/etc/letsencrypt/live/domain` exists, the bootstrap installs a Certbot deploy hook that copies `fullchain.pem` and `privkey.pem` into the Proxmox certificate files without symlinks and reloads `pveproxy` and `nginx`

### Firewall

The script configures nftables with:

- IPv4 forwarding
- IPv6 forwarding
- IPv4 masquerading for LAN traffic to WAN
- Optional NAT66 for ULA IPv6
- WAN and LAN access for:
  - SSH `22`
  - HTTP `80`
  - HTTPS `443`
  - Proxmox UI `8006`
- LAN-only DNS and DHCP by default
- WAN DNS only when `DNS_WAN_ENABLE=yes`
- WAN mail only when explicitly enabled or required by the selected Postfix mode

## Repositories and Hardening

Default behavior:

- Disable Proxmox enterprise repositories
- Enable Proxmox no-subscription repositories
- Use Deb822 `.sources` files on Proxmox VE 9+
- Use legacy `.list` files on older supported releases
- Preserve required Debian components including firmware repositories where applicable
- Suppress safe APT non-free-firmware source warnings
- Apply a non-interactive package upgrade by default
- Pin the newest installed Proxmox kernel by default
- Keep two installed Proxmox kernel versions total by default
- Configure fail2ban for SSH protection
- Keep AppArmor enabled in production
- Remove the Proxmox subscription nag and install an upgrade-persistent reapply hook

### Built-in Post-Install Automation

The safe non-interactive subset of the community post-install workflow is implemented directly in `install.sh`.

That built-in automation includes:

- repository normalization
- non-interactive package upgrade
- subscription nag removal with persistent reapply hook
- Proxmox kernel pinning and old-kernel cleanup

It does **not** automatically apply interactive or site-specific choices such as HA toggles or forced reboot prompts. The script finishes with a summary and recommends a reboot when kernel or core packages changed.

## VM and LXC Defaults

- Guests should default to the resolved LAN bridge
- A separate router-lab bridge is created for pfSense or other router/firewall LAN testing when LAN is dummy-backed
- Existing VM and LXC configs may be updated where safe
- Complex or clearly intentional custom guest networking should not be broken
- `GUEST_DEFAULT_BRIDGE` defaults to the resolved LAN bridge
- SPICE defaults should be applied where appropriate for VMs
- Current safety rule: only simple single-NIC guests are retargeted automatically

## SDN and VLAN

- `8021q` is loaded and persisted by default
- The bootstrap-managed router-lab bridge is created with `bridge-vlan-aware yes`
- SDN prerequisite packages may be installed when needed
- `CONFIGURE_SDN=no` means prepare prerequisites only
- `CONFIGURE_SDN=yes` allows conservative starter SDN object creation without overwriting existing SDN config

## Downloads

ISO and template downloads are optional and disabled by default.

Download behavior:

- Skip cleanly when disabled
- Use the correct upstream per image
- Prefer the latest available minimal installer image where the upstream publishes one, instead of oversized DVD media or boot-only images
- Avoid large downloads during automated testing unless explicitly requested
- Continue even if one optional download fails
- Track ISO and template completion per artifact so reruns can skip successful downloads

Target ISO set:

- Debian
- Ubuntu LTS
- AlmaLinux
- Rocky Linux
- XCP-ng
- pfSense CE

VMware ESXi is not auto-downloaded because of licensing restrictions.

## Optional Third-Party Tools

If enabled, the script downloads these tools locally and prints where to run them manually:

- ProxMenux
- Community Proxmox post-install script

Enable them with:

```bash
export RUN_PROXMENUX=yes
export RUN_POST_INSTALL=yes
./install.sh
```

Downloaded files are saved under:

```text
/usr/local/share/proxmox-bootstrap/tools/
```

The bootstrap does not execute third-party interactive scripts automatically.

Notes:

- `RUN_POST_INSTALL=yes` only downloads the community script for manual use; its safe non-interactive defaults are already built into `install.sh`
- `RUN_PROXMENUX=yes` only downloads the ProxMenux installer; its monitor remains a separate manual web dashboard install and is not auto-enabled by this bootstrap

## State and Idempotency

State is tracked in:

```text
/var/lib/proxmox-bootstrap-state
```

The goal is safe re-runs:

- completed tasks can be skipped
- `--status` shows tracked completion state
- `--clear-state` allows selective reruns
- downloads track individual state where practical
- optional third-party downloads are tracked independently

## Logging, Backups, and Files

Key paths:

```text
/etc/proxmox-bootstrap.conf
/etc/network/interfaces
/etc/nftables.conf
/etc/bind/named.conf
/etc/bind/zones.conf
/etc/bind/rndc.key
/etc/bind/dhcp.key
/etc/dhcp/dhcpd.conf
/etc/dhcp/dhcpd6.conf
/etc/radvd.conf
/etc/postfix/main.cf
/etc/letsencrypt/renewal-hooks/deploy/proxmox-bootstrap-copy-pve-cert
/etc/nginx/vhosts.d/
/var/log/proxmox-bootstrap/bootstrap.log
/mnt/Backups/proxmox/
/var/lib/proxmox-bootstrap-state
/var/lib/proxmox-bootstrap-state.network
```

Notes:

- Modified files are backed up before changes
- `/mnt/Backups/proxmox/` is intended for a dedicated backup mount; override `BACKUP_BASE_DIR` if you want backups elsewhere
- Backups are preserved during reset for manual recovery
- Log output to files is plain text

## Reset

`--reset` is intended to return the system to a clean Proxmox install as closely as practical by removing bootstrap-managed configuration, generated state, hooks, keys, and bootstrap-only packages while preserving backups.

## Testing

Primary test target:

```bash
docker run -itd --name proxmoxve --hostname pve -p 8006:8006 --privileged rtedpro/proxmox:9.1.9
```

Project verification should execute `install.sh` inside the declared Proxmox test container, not on the host.

Typical validation commands inside the container:

```bash
bash -n install.sh
nft -c -f /etc/nftables.conf
named-checkconf /etc/bind/named.conf
dhcpd -t -cf /etc/dhcp/dhcpd.conf
radvd -C /etc/radvd.conf -n -c
systemctl is-active bind9 isc-dhcp-server radvd nftables
```

## License

MIT. See [LICENSE.md](LICENSE.md).
