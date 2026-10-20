# IPL Secure MCP Installer

Community-maintained Linux installer for [OpenAI Tunnel Client](https://github.com/openai/tunnel-client) and the independent [chatgpt-mcp](https://github.com/alexcodeplace/chatgpt-mcp) project. **Not affiliated with or endorsed by OpenAI.**

The installer provides two **separate** MCP tunnel profiles:

| Mode | Runtime | Access | Startup |
| --- | --- | --- | --- |
| STANDARD | Dedicated non-root `mcp-agent` user | Explicitly configured filesystem roots; no shell | Enabled at boot |
| ADMIN | `root` | Full filesystem and unrestricted MCP shell commands | Manual only; default 2-hour limit |

> **Security warning:** ADMIN is a remote root management channel, not a sandbox. OpenAI-side tool checks may independently deny operations. Do not expose an ADMIN tunnel or its API key to people you do not trust.

## Requirements

- Linux x86_64 or ARM64, with **systemd**, `sudo`, `useradd`, `runuser`, `flock`, `realpath`, `systemd-analyze`, `curl`, `unzip`, `git`, `python3`, `sha256sum`, `timeout`.
- Node.js **22+** and npm.
- Network access to GitHub, npm registry and OpenAI.
- A separately created OpenAI Tunnel ID and limited runtime API key for each intended connection. **Never commit or paste API keys into GitHub.**
- Interactive terminal with sudo access. No unattended mode yet.

The installer checks prerequisites; it does **not** install OS packages or Node.js.

## Quick start

Download or clone this repository, inspect `install.sh`, and run:

```bash
sudo bash install.sh --mode standard --host MY-LINUX-HOST
```

At the prompts, provide your dedicated STANDARD Tunnel ID and runtime key. Press Enter for the default filesystem root `/var/lib/mcp-agent/workspace`.

After successful installation, the installer verifies local tunnel readiness and enables the STANDARD systemd service. Create a ChatGPT custom MCP connection using **Tunnel**, the corresponding Tunnel ID, and **No Authentication**.

Check from ChatGPT: `system.info`, `fs.write`, `fs.read`, and rejection of a path outside the configured roots (`PATH_NOT_ALLOWED`). These external checks are **not automated** by the installer.

Once STANDARD is verified, the optional ADMIN installation is:

```bash
sudo bash install.sh --mode admin --host MY-LINUX-HOST
mcp-admin-start
# When finished:
mcp-admin-stop
```

The ADMIN installation requires explicit confirmation of unrestricted root access, a **different Tunnel ID**, and remains disabled at boot. The `mcp-admin-start` and `mcp-admin-stop` helpers use sudo/systemd.

To set a host-specific ADMIN lifetime (example: eight hours):

```bash
sudo mkdir -p /etc/systemd/system/ipl-mcp-admin.service.d
printf '[Service]\nRuntimeMaxSec=8h\n' | sudo tee /etc/systemd/system/ipl-mcp-admin.service.d/timeout.conf >/dev/null
sudo systemctl daemon-reload
systemctl show ipl-mcp-admin.service -p RuntimeMaxUSec -p UnitFileState
```

## Additional STANDARD directories

Extra roots must exist, be canonical absolute paths, and be readable and writable by `mcp-agent`. The installer **does not change existing directory permissions**. If access is required under a private home directory, plan narrowly scoped ACLs with the directory owner; ensure parent traversal and subdirectory permissions are adequate. `ProtectSystem=strict` also requires matching `ReadWritePaths=` lines in the standard systemd unit.

Changing installed roots currently requires **manual configuration** of both `/etc/ipl-mcp/standard.json` and `ipl-mcp-standard.service`, followed by `systemctl daemon-reload` and service restart. See [filesystem access](docs/filesystem-access.md).

## Status and limitations

- **v0.4.4** is for **new installations**; no supported in-place upgrade/reinstall yet. Do not rerun over an existing installation.
- Initial STANDARD and ADMIN setup was manually validated on clean Debian 13 and Ubuntu 26.04 test systems. The exact v0.4.4 package has **not** been independently clean-installed end-to-end.
- The upstream project has a known failing timing-sensitive reliability test; this installer explicitly skips the full project test suite but builds the pinned source and checks local readiness.
- Rollback is **best effort**, not transactional.
- Tunnel readiness does not prove ChatGPT-level connectivity, tool permissions, or a complete security audit.
- ADMIN may be rejected by additional platform safety checks even when Linux and local MCP policy allow the operation.

Full instructions: [Installation guide](docs/installation.md). Changes: [Changelog](CHANGELOG.md). Known work: [GitHub Issues](../../issues).

## License

MIT for this repository's own code and documentation. Upstream dependencies retain their own licenses. Do not copy upstream source code or bundled binaries into this repository without license review.
