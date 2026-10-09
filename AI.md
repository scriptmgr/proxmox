# proxmox — AI Spec

## PART 0 — Project Identity

- **Name:** proxmox
- **Type:** shell script (single script, no build step)
- **Shell:** bash
- **Primary script:** install.sh
- **Description:** Idempotent, non-interactive Proxmox VE bootstrap that turns a fresh host into a routed/NAT LAN environment for VMs and containers.

## PART 1 — Scope

- `install.sh` is the only deliverable. It is the build, install, and runtime entrypoint; there is no Makefile, toolchain image, or CI workflow.
- Supported targets: Proxmox VE 7.x, 8.x, 9.x. `__detect_pve_version` exits when `pveversion` is missing or the major version is below 7.
- First run must work with zero configuration. Every setting has a built-in default.
- User-facing behavior (flags, variables, defaults, paths) is documented in `README.md`; keep it in sync with the script.

## PART 2 — Script Rules

- All functions are `__`-prefixed; locals are declared with `local`.
- Top-level options are `set -eo pipefail`; failures that must stop the run call `__log_fatal`.
- Indent with tabs, as the existing file does. Comments go above the code, never inline.
- Every `grep` call uses `--` before the pattern.
- Prefer parameter expansion over `dirname`/`basename`, and `cat file` over `$(< file 2>/dev/null)` (the latter is a no-op in bash when it carries an extra redirect).
- Heredocs that must expand variables are unquoted and escape nginx/shell variables with `\$`; quoted heredocs are for literal content only.
- Unknown options print usage to stderr and exit `2`; `--help`, `--version`, `--status`, `--clear-state`, and `--reset` exit `0`.
- `--debug` enables `set -x` after argument parsing. Traces go to the terminal only.

## PART 3 — Configuration

Precedence, highest to lowest:

1. Runtime environment variables
2. `./.env`
3. `/etc/proxmox-bootstrap.conf`
4. Built-in defaults (`VAR="${VAR:-default}"` near the top of `install.sh`)

`--init` writes the effective configuration after applying that precedence.

## PART 4 — Idempotency and Safety

- Work runs through `__run_task name function`; completion is recorded in `/var/lib/proxmox-bootstrap-state`. `--force` ignores recorded state; `--clear-state [task]` removes it.
- Back up every file before modifying it with `__backup_file`; backups live under `PROXMOX_BACKUP_BASE_DIR` (default `/mnt/Backups/proxmox`) and survive `--reset`.
- Network changes are additive: existing WAN settings are never changed unless explicit WAN variables are supplied, and unused NICs are left alone.
- `__proxmox_init` runs right after the network task and brings the node to a working state, in order: `__ensure_node_hosts_entry` (the node name must resolve to a non-loopback IP in `/etc/hosts`, or `pmxcfs` refuses to start; it maps the node to the primary route address (the source address for reaching the internet, which is the management address other nodes and the certificate use), falls back to the static LAN bridge address `LAN_V4_IP` only when no route exists, and replaces an existing entry whose IP is no longer assigned to this host, so DHCP changes cannot leave it stale), `__ensure_pve_cluster` (start `pve-cluster` so `/etc/pve` is mounted), `__ensure_pve_node_dir` (make `/etc/pve/nodes/{node}` match the target node name, which is `PVE_NODE_NAME` or the short hostname), and `__ensure_pve_cert` (regenerate a missing `pve-ssl.pem` or `pve-ssl.key` with `pvecm updatecerts --force`). A missing certificate means Proxmox is broken.
- Anything that touches `/etc/pve` must run after `__proxmox_init`; `/etc/pve` is empty while `pve-cluster` is down.
- Never write credentials into the log, the summary, or committed files. Relay passwords are only written to `/etc/postfix/sasl_passwd` with mode `600`.
- Third-party interactive installers (ProxMenux) are downloaded, never executed.

## PART 5 — Testing and Quality

Proxmox VE is not installed on the development host. Never run `install.sh` on the host; run it inside the declared Proxmox test container.

Primary test target (`rtedpro/proxmox:latest`):

```bash
docker run -itd --name proxmoxve --hostname pve -p 8006:8006 --privileged rtedpro/proxmox:latest
```

Run the whole sequence with `tests/container-test.sh`. It pulls `PROXMOX_TEST_IMAGE` (default `rtedpro/proxmox:latest`) and runs a three-scenario matrix, each in a fresh privileged container with a random hostname so the test does not only pass for the name baked into the image:

- `random`: random short hostname, node name follows the hostname
- `node-name`: random hostname plus a different `PVE_NODE_NAME` (the rename path)
- `fqdn`: random hostname that is already a fully qualified name

Each scenario runs `install.sh` twice (the second run checks idempotency), then runs the validation commands below plus hostname, `/etc/hosts`, `pve-cluster`, node directory, certificate, `nginx -t` and service checks. `--scenario NAME` runs one scenario, `PROXMOX_TEST_HOSTNAME` pins the base hostname to reproduce a failure, and `--keep` leaves containers and logs for inspection. Failed scenarios keep their container; logs go to a temp directory outside the project.

Image notes (`rtedpro/proxmox` is built for Docker and ships build-time stubs that stay in place at runtime):

- `/usr/local/sbin/systemctl` is a no-op (`exit 0`) that comes before the real `/usr/bin/systemctl` on `PATH`. Bare `systemctl` calls do nothing and `is-active` always succeeds. `tests/container-test.sh` removes it in each container before the install runs; for a manual container, run `docker exec proxmoxve rm -f /usr/local/sbin/systemctl` or use a login shell (which resets `PATH`).
- `/usr/sbin/ifreload` exits 0 for everything except `-V`, so network reloads never apply live. Checks validate generated config, not live bridges.
- `/usr/lib/modules`, `/boot` and `/usr/lib/firmware` are removed, so `modprobe` cannot load modules.
- PID 1 is the real systemd (via `/usr/local/bin/entrypoint.sh`), and a healthy container reports `running` or `degraded` from `/usr/bin/systemctl is-system-running`.
- Inspect the image without the Docker daemon with `skopeo inspect docker://docker.io/rtedpro/proxmox:latest` or `skopeo copy` to a directory under a temp path.

Image tags and scope (from the `rtedpro-cpu/dockermox` project that builds the image):

- Release tags are `rtedpro/proxmox:9.2.11` (slim, about 2 GB) and `rtedpro/proxmox:9.2.11-full` (about 4 GB, keeps kernel modules and firmware). `latest` is not a release; pin a tag with `PROXMOX_TEST_IMAGE` for reproducible runs, and use the `-full` tag to exercise paths that need `modprobe`.
- Only the amd64 images are tested. The arm64 image is a different build (from PXVIRT, root password `root`).
- The host must have `/dev/fuse` (load the `fuse` module if it is missing); `tests/container-test.sh` stops early without it.
- No `vmbr0` bridge exists in the container by default, and `install.sh` defaults its WAN bridge to `vmbr0`. Network checks cover generated config, not live bridges.
- Applying network configuration in the privileged container may reboot the host (a documented dockermox warning), so run the matrix only on a disposable machine.

Rules:

- The Docker daemon must be running.
- Project verification executes `install.sh` inside that container, not on the host.
- The container is privileged and shares the host kernel, so `install.sh` kernel-level changes (modules, `kvm` nested parameter) reach the host. Run it on a disposable test machine.
- Avoid large downloads (ISOs, templates) during automated testing unless explicitly requested; `DOWNLOAD_ISOS` and `DOWNLOAD_TEMPLATES` stay `no`.
- Remove the container as soon as testing is finished.

Typical validation commands, run inside the container:

```bash
bash -n install.sh
nft -c -f /etc/nftables.conf
named-checkconf /etc/bind/named.conf
dhcpd -t -cf /etc/dhcp/dhcpd.conf
radvd -C /etc/radvd.conf -n -c
systemctl is-active bind9 isc-dhcp-server radvd nftables
```

Gate before every commit (host side, no Proxmox needed):

- `shellcheck install.sh` exits 0
- `bash -n install.sh` exits 0
- the `script-lint` agent reports 0 new issues

## PART 6 — Documentation

- `README.md` documents every flag, configuration variable, default, and managed path. Update it in the same commit as any behavior change.
- `install.sh` has `__usage` rather than a `__help()` function, and ships no man page or completions.
- License is MIT, in `LICENSE.md`.
