#!/usr/bin/env node
'use strict';

const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn, execFile } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const CONFIG_PATH = path.join(REPO_ROOT, 'config', 'config.yaml');
const PORT = process.env.RUNBOOK_PORT || 4848;

// Cortex's connector files (values.yaml, auth.json) are a few KB; cap well
// above that so a wrong file selection fails fast instead of hanging.
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 25 * 1024 * 1024 } });

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ---------------------------------------------------------------------------
// In-memory session state. Nothing here ever touches disk: credentials live
// only as long as this server process does, which is the point — this app
// runs on the student's own workstation for the duration of one lab session.
// ---------------------------------------------------------------------------
let creds = null; // { accessKeyId, secretAccessKey, sessionToken, region }

function credsEnv() {
  if (!creds) return {};
  const env = {
    AWS_ACCESS_KEY_ID: creds.accessKeyId,
    AWS_SECRET_ACCESS_KEY: creds.secretAccessKey,
    AWS_REGION: creds.region,
    AWS_DEFAULT_REGION: creds.region,
  };
  if (creds.sessionToken) env.AWS_SESSION_TOKEN = creds.sessionToken;
  return env;
}

function mask(key) {
  if (!key) return '';
  if (key.length <= 8) return '*'.repeat(key.length);
  return key.slice(0, 4) + '…' + key.slice(-4);
}

// ---------------------------------------------------------------------------
// config/config.yaml — read the two fields the UI needs, and update
// stackPrefix in place with a targeted line replace so every comment and the
// stack list are left exactly as they are.
// ---------------------------------------------------------------------------
function readConfig() {
  const text = fs.readFileSync(CONFIG_PATH, 'utf8');
  const region = /^region:\s*(\S+)/m.exec(text)?.[1] || '';
  const stackPrefix = /^stackPrefix:\s*(\S+)/m.exec(text)?.[1] || '';
  const isPlaceholder = stackPrefix.includes('XX') || !/grp[0-9]+/.test(stackPrefix);
  return { region, stackPrefix, isPlaceholder };
}

function writeStackPrefix(newPrefix) {
  const text = fs.readFileSync(CONFIG_PATH, 'utf8');
  if (!/^stackPrefix:\s*\S+/m.test(text)) {
    throw new Error('stackPrefix line not found in config.yaml');
  }
  const updated = text.replace(/^stackPrefix:\s*\S+.*$/m, `stackPrefix: ${newPrefix}`);
  fs.writeFileSync(CONFIG_PATH, updated, 'utf8');
}

// ---------------------------------------------------------------------------
// Run registry — every long-running command (shell scripts, one-off aws
// calls) goes through here so the browser can attach a live log stream.
// Commands are always spawned as argv arrays (shell: false), so user-supplied
// values like a local file path can never be interpreted as shell syntax.
// ---------------------------------------------------------------------------
const runs = new Map(); // id -> { status, log: [{stream,text}], exitCode, emitter, proc }

function startRun({ cmd, args, cwd, stdinY, stdinBuffer }) {
  const id = crypto.randomUUID();
  const emitter = new (require('events').EventEmitter)();
  const record = { status: 'running', log: [], exitCode: null, emitter, startedAt: Date.now() };
  runs.set(id, record);

  const child = spawn(cmd, args, {
    cwd: cwd || REPO_ROOT,
    env: { ...process.env, ...credsEnv() },
    shell: false,
  });
  record.proc = child;

  const push = (stream, chunk) => {
    const text = chunk.toString('utf8');
    record.log.push({ stream, text });
    emitter.emit('data', { stream, text });
  };

  child.stdout.on('data', (c) => push('out', c));
  child.stderr.on('data', (c) => push('err', c));

  if (stdinY) {
    // scripts/delete.sh prompts "Delete stacks in <region>? [y/N]"; the UI's
    // own confirmation checkbox is the real gate, so auto-answer the script's.
    child.stdin.write('y\n');
  }
  if (stdinBuffer) {
    // e.g. "aws s3 cp - s3://..." reading the uploaded file from stdin.
    child.stdin.write(stdinBuffer);
    child.stdin.end();
  }

  child.on('close', (code) => {
    record.status = code === 0 ? 'success' : 'failed';
    record.exitCode = code;
    emitter.emit('done', { exitCode: code });
  });
  child.on('error', (err) => {
    push('err', Buffer.from(`\n[runbook] failed to start: ${err.message}\n`));
    record.status = 'failed';
    emitter.emit('done', { exitCode: -1 });
  });

  return id;
}

app.get('/api/run/:id/stream', (req, res) => {
  const record = runs.get(req.params.id);
  if (!record) return res.status(404).end();

  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  res.flushHeaders?.();

  for (const entry of record.log) {
    res.write(`event: data\ndata: ${JSON.stringify(entry)}\n\n`);
  }
  if (record.status !== 'running') {
    res.write(`event: done\ndata: ${JSON.stringify({ exitCode: record.exitCode, status: record.status })}\n\n`);
    return res.end();
  }

  const onData = (entry) => res.write(`event: data\ndata: ${JSON.stringify(entry)}\n\n`);
  const onDone = ({ exitCode }) => {
    res.write(`event: done\ndata: ${JSON.stringify({ exitCode, status: runs.get(req.params.id).status })}\n\n`);
    res.end();
  };
  record.emitter.on('data', onData);
  record.emitter.once('done', onDone);
  req.on('close', () => {
    record.emitter.off('data', onData);
    record.emitter.off('done', onDone);
  });
});

app.get('/api/run/:id', (req, res) => {
  const record = runs.get(req.params.id);
  if (!record) return res.status(404).json({ error: 'not found' });
  res.json({ status: record.status, exitCode: record.exitCode });
});

app.post('/api/run/:id/stop', (req, res) => {
  const record = runs.get(req.params.id);
  if (!record) return res.status(404).json({ error: 'not found' });
  if (record.status === 'running') record.proc.kill('SIGTERM');
  res.json({ ok: true });
});

// ---------------------------------------------------------------------------
// Tool / environment checks (step 0 — prerequisites)
// ---------------------------------------------------------------------------
const TOOL_CHECKS = [
  { name: 'AWS CLI v2', cmd: 'aws', args: ['--version'] },
  { name: 'Session Manager plugin', cmd: 'session-manager-plugin', args: ['--version'] },
  { name: 'Python 3', cmd: 'python3', args: ['--version'] },
  { name: 'cfn-lint', cmd: 'cfn-lint', args: ['--version'] },
  { name: 'git', cmd: 'git', args: ['--version'] },
];

function checkTool({ name, cmd, args }) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 5000 }, (err, stdout, stderr) => {
      if (err) return resolve({ name, found: false });
      resolve({ name, found: true, version: (stdout || stderr).toString().trim().split('\n')[0] });
    });
  });
}

app.get('/api/tools', async (req, res) => {
  res.json(await Promise.all(TOOL_CHECKS.map(checkTool)));
});

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------
app.get('/api/credentials', (req, res) => {
  if (!creds) return res.json({ set: false });
  res.json({
    set: true,
    accessKeyId: mask(creds.accessKeyId),
    region: creds.region,
    hasSessionToken: !!creds.sessionToken,
  });
});

app.post('/api/credentials', (req, res) => {
  const { accessKeyId, secretAccessKey, sessionToken, region } = req.body || {};
  if (!accessKeyId || !secretAccessKey || !region) {
    return res.status(400).json({ error: 'accessKeyId, secretAccessKey and region are required' });
  }
  creds = { accessKeyId, secretAccessKey, sessionToken: sessionToken || '', region };
  res.json({ ok: true });
});

app.delete('/api/credentials', (req, res) => {
  creds = null;
  res.json({ ok: true });
});

app.post('/api/credentials/test', (req, res) => {
  if (!creds) return res.status(400).json({ error: 'No credentials loaded yet.' });
  execFile('aws', ['sts', 'get-caller-identity', '--output', 'json'], {
    env: { ...process.env, ...credsEnv() },
    timeout: 15000,
  }, (err, stdout, stderr) => {
    if (err) return res.status(400).json({ error: (stderr || err.message).trim() });
    try {
      res.json({ ok: true, identity: JSON.parse(stdout) });
    } catch {
      res.status(500).json({ error: 'Could not parse aws sts output' });
    }
  });
});

// ---------------------------------------------------------------------------
// config.yaml — stack prefix
// ---------------------------------------------------------------------------
app.get('/api/config', (req, res) => {
  try {
    res.json(readConfig());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/config/stack-prefix', (req, res) => {
  const { groupNumber } = req.body || {};
  const n = parseInt(groupNumber, 10);
  if (!Number.isInteger(n) || n < 0) {
    return res.status(400).json({ error: 'Enter a valid group number, e.g. 7' });
  }
  const padded = String(n).padStart(2, '0');
  const prefix = `sko26-grp${padded}-cortexlab`;
  try {
    writeStackPrefix(prefix);
    res.json(readConfig());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// CloudFormation lookups — used to pre-fill the copy-paste commands for the
// steps that have to be run by hand (interactive SSM shells, console work).
// ---------------------------------------------------------------------------
app.get('/api/stack-output', (req, res) => {
  if (!creds) return res.status(400).json({ error: 'Load AWS credentials first.' });
  const { stack, key } = req.query;
  if (!stack || !key) return res.status(400).json({ error: 'stack and key query params are required' });
  let cfg;
  try {
    cfg = readConfig();
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
  const stackName = `${cfg.stackPrefix}-${stack}`;
  execFile('aws', [
    'cloudformation', 'describe-stacks',
    '--stack-name', stackName,
    '--query', `Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue`,
    '--output', 'text',
  ], { env: { ...process.env, ...credsEnv() }, timeout: 20000 }, (err, stdout, stderr) => {
    if (err) return res.status(404).json({ error: (stderr || err.message).trim(), stackName });
    const value = stdout.trim();
    if (!value || value === 'None') return res.status(404).json({ error: `No output '${key}' on ${stackName} yet`, stackName });
    res.json({ value, stackName });
  });
});

const EXPECTED_STACKS = ['cloudtrail', 'vpc', 'network-logging', 'transfer-bucket', 'linux-vm', 'win-vm', 'eks'];

app.get('/api/stacks/status', (req, res) => {
  if (!creds) return res.status(400).json({ error: 'Load AWS credentials first.' });
  let cfg;
  try {
    cfg = readConfig();
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
  execFile('aws', [
    'cloudformation', 'list-stacks',
    '--query', `StackSummaries[?starts_with(StackName, '${cfg.stackPrefix}') && StackStatus!='DELETE_COMPLETE'].{Name:StackName,Status:StackStatus}`,
    '--output', 'json',
  ], { env: { ...process.env, ...credsEnv() }, timeout: 20000 }, (err, stdout, stderr) => {
    if (err) return res.status(500).json({ error: (stderr || err.message).trim() });
    let found;
    try {
      found = JSON.parse(stdout);
    } catch {
      return res.status(500).json({ error: 'Could not parse aws cloudformation output' });
    }
    const byName = new Map(found.map((s) => [s.Name.slice(cfg.stackPrefix.length + 1), s.Status]));
    const stacks = EXPECTED_STACKS.map((name) => ({ name, status: byName.get(name) || 'not deployed' }));
    res.json({ stackPrefix: cfg.stackPrefix, stacks });
  });
});

// ---------------------------------------------------------------------------
// Actions — the only commands this server will ever spawn. Each is a fixed
// argv array; the handful of user-supplied values (local file path, group
// number) are inserted as array elements, never concatenated into a shell
// string, so they can't be used to inject extra commands.
// ---------------------------------------------------------------------------
// The repo's scripts aren't checked in with the executable bit set (common
// after a plain git clone, especially on Windows), so run them through bash
// explicitly rather than relying on the shebang + exec bit.
app.post('/api/actions/validate', (req, res) => {
  res.json({ runId: startRun({ cmd: 'bash', args: ['scripts/validate.sh'] }) });
});

app.post('/api/actions/deploy-part1', (req, res) => {
  if (!creds) return res.status(400).json({ error: 'Load AWS credentials first.' });
  res.json({ runId: startRun({ cmd: 'bash', args: ['scripts/deploy-part1.sh'] }) });
});

app.post('/api/actions/deploy-part2', (req, res) => {
  if (!creds) return res.status(400).json({ error: 'Load AWS credentials first.' });
  res.json({ runId: startRun({ cmd: 'bash', args: ['scripts/deploy-part2.sh'] }) });
});

app.post('/api/actions/delete', (req, res) => {
  if (!creds) return res.status(400).json({ error: 'Load AWS credentials first.' });
  if (req.body?.confirm !== true) return res.status(400).json({ error: 'Confirmation required.' });
  res.json({ runId: startRun({ cmd: 'bash', args: ['scripts/delete.sh'], stdinY: true }) });
});

// Browser-side file picker upload: the file's bytes arrive in the request
// body (memory, never written to disk here) and are piped straight to
// "aws s3 cp - s3://...", so the uploaded file's original name is preserved —
// Cortex's generated filenames matter later, when you reference them in the
// helm commands on the Linux VM.
app.post('/api/actions/upload-cortex-file', upload.single('file'), (req, res) => {
  if (!creds) return res.status(400).json({ error: 'Load AWS credentials first.' });
  if (!req.file) return res.status(400).json({ error: 'No file received.' });
  const bucket = req.body?.bucket;
  if (!bucket) return res.status(400).json({ error: 'bucket is required' });
  const filename = path.basename(req.file.originalname);
  res.json({
    runId: startRun({
      cmd: 'aws',
      args: ['s3', 'cp', '-', `s3://${bucket}/cortex/${filename}`, '--region', creds.region],
      stdinBuffer: req.file.buffer,
    }),
    filename,
  });
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`\nCortex Lab runbook running at http://localhost:${PORT}\n`);
});
