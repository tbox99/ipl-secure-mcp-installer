# Changelog

Changes in this repository follow the format of a human-readable change log. Versions describe the installer, not the external MCP or Tunnel Client projects.

## 0.4.4 — 2026-10-20

- Install STANDARD and ADMIN independently, with separate tunnel identities.
- Pin OpenAI Tunnel Client v0.0.16 and the chosen MCP source commit.
- Build the MCP as a dedicated unprivileged user; install code owned by root.
- Correct the installed MCP tree's read/traverse permissions for the runtime service user.
- Create intermediate `.config` directories with the intended service user ownership (fix discovered on Ubuntu).
- Correct placement of systemd `ReadWritePaths`.
- Provide on-demand `mcp-admin-start` and `mcp-admin-stop` helpers, with rollback coverage.
- Permit multiple STANDARD filesystem roots when OS permissions allow.
- Keep ADMIN disabled at boot and time-limited (two hours by default).

### Known limitations

No in-place upgrade, no unattended install, best-effort rollback, and no automated ChatGPT end-to-end verification. The complete upstream test gate is not run.
