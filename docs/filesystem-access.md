# Filesystem access

STANDARD runs as the dedicated, unprivileged `mcp-agent`. A path must satisfy **all** of these conditions:

1. It is a configured entry in `filesystem.roots` in `/etc/ipl-mcp/standard.json`.
2. The Linux user `mcp-agent` can traverse parent directories and read/write relevant files and directories.
3. The systemd `ProtectSystem=strict` sandbox has a corresponding `ReadWritePaths=` exception.

The installer intentionally **does not** change pre-existing file ownership, group permissions, or ACLs. For folders in a private user home, inspect existing ACLs and agree on narrow additions before making changes. Existing children may need individual ACL review; default ACL entries apply to future children, not older ones.

To add a path to an existing installation, make backed-up, coordinated changes to the JSON roots and to the systemd unit's `[Service]` section. Verify with `systemd-analyze verify`, reload systemd, then restart the STANDARD service. Check effective access through the actual MCP tools. An installer-managed update workflow is planned but not yet available.

ADMIN is configured separately with `filesystem.roots=["/"]`, runs as root, and is not subject to the STANDARD root restrictions. A time limit constrains session length, **not** the privileges of commands run during that session.
