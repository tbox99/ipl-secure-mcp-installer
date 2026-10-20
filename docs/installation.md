# Installation and operational guide

This is a **general** guide. Never commit passwords, API keys, tunnel IDs, host inventories, private IP addresses, or unredacted diagnostic logs.

## 1. Decide which access to expose

Choose STANDARD first. It uses `mcp-agent` with filesystem operations inside configured roots and no shell. ADMIN is optional and executes as root, with wildcard shell and a `/` filesystem root. Treat ADMIN as a high-risk, temporary management connection.

Create **distinct Tunnel IDs** for STANDARD and ADMIN and use minimally scoped runtime API keys according to your OpenAI Platform account permissions.

## 2. Check prerequisites

```bash
node --version  # must be >=22
for c in curl unzip git python3 npm systemctl sha256sum timeout runuser realpath systemd-analyze flock useradd groupadd getent; do
  command -v "$c" || echo "MISSING: $c"
done
bash -n install.sh
```

Supported CPU architectures: amd64 and arm64. Linux distribution support is not exhaustive; the script assumes a systemd Linux host with GNU-style administrative tools.

## 3. STANDARD installation

```bash
sudo bash install.sh --mode standard --host MY-LINUX-HOST
```

The installer prompts for the tunnel ID, hidden runtime key, and STANDARD roots (default `/var/lib/mcp-agent/workspace`). It checks integrity of the tunnel-client archive, pins an MCP Git commit, installs dependencies with a fixed pnpm version and lockfile, builds unprivileged, creates systemd service, and checks local `/readyz`.

```bash
systemctl is-active ipl-mcp-standard.service
systemctl is-enabled ipl-mcp-standard.service
curl -fsS http://127.0.0.1:18080/readyz
```

Connect the STANDARD Tunnel ID to ChatGPT as a custom MCP connection with No Authentication. Test real tool connectivity and ensure access to an unapproved path is denied.

## 4. Optional ADMIN installation

```bash
sudo bash install.sh --mode admin --host MY-LINUX-HOST
mcp-admin-start
systemctl is-active ipl-mcp-admin.service
curl -fsS http://127.0.0.1:28080/readyz
```

Connect with the separate ADMIN Tunnel ID. Verify host identity and permissions cautiously; distinguish policy-denied operations from transport failures. ADMIN uses full root access, so limit sessions and stop promptly:

```bash
mcp-admin-stop
```

The default `RuntimeMaxSec=2h` starts counting when the service becomes active. A systemd drop-in can override this per host.

## 5. Filesystem roots and updates

See [filesystem access](filesystem-access.md) for additional directories and permission planning. The installer intentionally prevents overwriting an existing installation. There is no supported upgrade path yet; do not rerun it to change roots or timeout.

## 6. Acceptance checklist

- STANDARD service is active and enabled at boot; ADMIN is disabled at boot.
- ChatGPT connects to both identities independently.
- STANDARD reads/writes within its approved workspace and denies out-of-root paths.
- ADMIN is started only when needed; confirms expected identity; stop works.
- STANDARD returns after reboot; ADMIN stays stopped. Check on each target distribution.
- Check logs without exposing secrets, and revoke temporary test keys after testing.

## 7. Troubleshooting

- `permission denied` on `stdio.js`: verify traverse/read permissions for the runtime user throughout the installed MCP directory tree.
- Profile initialization failure: verify ownership and mode of the home, `.config`, and `.config/tunnel-client` directories.
- Extra root writable in Linux but not via MCP: verify both `filesystem.roots` in JSON and `ReadWritePaths=` in the systemd unit.
- `active` but no `readyz`: allow startup time; review `journalctl -u ipl-mcp-standard.service` or the ADMIN unit.
- Tool call denied despite root service: separate application policy and platform safety decisions from OS-level permissions.
- Partial install: cleanup is best effort. Inspect before retrying; do not blindly delete unrelated paths.
