# Durable MCP Jobs — isolated validation

This document accompanies a **test-only** smoke harness. It does not modify
live tunnel services, privileges, Git repositories other than this one,
configuration, runtime API keys, or host systemd units.

## Execute as the intended unprivileged job owner

From an existing terminal session with a running systemd user manager:

```bash
node tools/smoke-durable-jobs.mjs /absolute/path/to/installed/chatgpt-mcp
```

The test imports the existing upstream JobStore from the installed MCP server,
uses a disposable private /tmp directory and an in-memory minimal configuration,
and calls the already present systemd user launcher. It checks completion,
bounded output, replay prevention, denial of non-allowlisted shell commands,
denial of work directories outside the test root, and reuse of an operation ID
with changed arguments. It cleans up its temporary directory. Successful local
execution is **not** a ChatGPT-to-tunnel end-to-end test.

## Safe integration plan

The established STANDARD service runs as mcp-agent and currently disables
shell and jobs; ADMIN runs as root, with shell enabled and jobs disabled.
Do **not** flip a few configuration switches on either live service.

1. Develop a separate unprivileged developer runner as the repository owner
   (or a narrowly delegated worker with independently reviewed permissions).
2. Review command allowlists, filesystem / subprocess constraints, timeout,
   output/retention limits and the user systemd manager.
3. A separate authenticated tunnel/client connection requires its own
   user-approved credential setup; never reuse the root ADMIN secret.
4. Independently validate ChatGPT exec.start/status/output/cancel/list,
   duplicate IDs, reconnect recovery, cancellation and policy failures.
5. Preserve existing services and provide an explicit backup/rollback mechanism.
   The existing install.sh is **fresh-install-only** and must not overwrite them.

The community MCP runs commands with the job owner's OS rights: this can
include repository writes and Git credentials. Path roots alone are not
a comprehensive sandbox. Remote Desktop Commander remains an optional fallback.
