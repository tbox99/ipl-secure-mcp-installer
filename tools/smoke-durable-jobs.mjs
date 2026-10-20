#!/usr/bin/env node
/**
 * Non-mutating MCP JobStore smoke test.
 *
 * Runs only as an unprivileged user with a working systemd --user manager.
 * Exercises the installed community MCP implementation against disposable /tmp
 * storage. Does not access tunnel keys, live configurations or project repos.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const installedRoot = process.argv[2];
if (!installedRoot || !path.isAbsolute(installedRoot)) {
  console.error('Usage: node tools/smoke-durable-jobs.mjs /absolute/path/to/installed/chatgpt-mcp');
  process.exit(2);
}
if (typeof process.getuid !== 'function' || process.getuid() === 0) {
  console.error('REFUSED: run as the intended unprivileged job owner, never as root');
  process.exit(2);
}
if (process.platform !== 'linux') {
  console.error('REFUSED: this test requires Linux systemd --user');
  process.exit(2);
}
if (!process.env.XDG_RUNTIME_DIR || !process.env.DBUS_SESSION_BUS_ADDRESS) {
  console.error('REFUSED: missing user systemd bus; do not modify live services to bypass this');
  process.exit(2);
}
const configPath = path.join(installedRoot, 'config.example.json');
const jobStorePath = path.join(installedRoot, 'dist/src/execution/job-store.js');
const configuration = JSON.parse(await fs.readFile(configPath, 'utf8'));
const { JobStore } = await import(pathToFileURL(jobStorePath).href);
const base = await fs.mkdtemp(path.join(os.tmpdir(), 'mcp-job-smoke-'));
const failure = message => { throw new Error(message); };
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  configuration.filesystem.roots = [base];
  configuration.shell.enabled = true;
  configuration.shell.allowedCommands = ['python3'];
  configuration.shell.allowEnvironment = false;
  configuration.shell.maxOutputBytes = 65536;
  configuration.shell.defaultRuntimeMs = 5000;
  configuration.shell.maxRuntimeMs = 10000;
  configuration.jobs.enabled = true;
  configuration.jobs.launcher = 'systemd';
  configuration.jobs.directory = path.join(base, 'jobs');
  configuration.jobs.maxConcurrent = 1;
  configuration.jobs.maxStoredJobs = 5;
  configuration.jobs.maxStoredOutputBytes = 1048576;
  configuration.jobs.outputRetentionSeconds = 60;
  configuration.jobs.retentionSeconds = 120;
  configuration.execution.commandPolicies = [];
  const store = new JobStore(configuration);
  const op = 'smoke-mcp-jobs-01';
  const request = { command: 'python3', args: ['-c', "print('DURABLE_JOB_PASS')"], cwd: base, timeoutMs: 10000 };
  let initial = await store.start(op, request);
  const duplicate = await store.start(op, request);
  assert.equal(duplicate.jobId, initial.jobId, 'duplicate must not replay execution');

  for (let attempts = 0; attempts < 50; attempts++) {
    initial = await store.status(initial.jobId);
    if (['succeeded', 'failed', 'cancelled', 'unknown'].includes(initial.state)) break;
    await wait(100);
  }
  assert.equal(initial.state, 'succeeded', 'job must finish successfully');
  const output = await store.output(initial.jobId, 'stdout');
  assert.equal(output.text.trim(), 'DURABLE_JOB_PASS', 'expected bounded stdout not returned');

  await assert.rejects(
    () => store.start('smoke-mcp-jobs-02', { command: 'python3', args: ['-c', 'pass'], cwd: '/etc', timeoutMs: 10000 }),
    'outside-root cwd must be denied'
  );
  await assert.rejects(
    () => store.start('smoke-mcp-jobs-03', { command: 'bash', args: ['-c', 'true'], cwd: base, timeoutMs: 10000 }),
    'non-allowlisted shell must be denied'
  );
  await assert.rejects(
    () => store.start(op, { ...request, args: ['-c', "print('CHANGED')"] }),
    'reused operation ID with changed request must be denied'
  );

  console.log('PASS: systemd user job completed, output captured, duplicate never replayed');
  console.log('PASS: outside-root cwd, shell and conflicting operation ID rejected');
} finally {
  await fs.rm(base, { recursive: true, force: true });
}
