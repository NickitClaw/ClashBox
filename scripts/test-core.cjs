#!/usr/bin/env node
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createCoreOverlay } = require('../proxy_core/src/flclash/corepatches/overlay.cjs');
const root = path.resolve(__dirname, '..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'clashbox-core-'));
try {
  const overlay = createCoreOverlay(temp);
  const result = spawnSync(process.env.GO_BIN || 'go', ['test', '-mod=readonly', '-race', '-overlay', overlay, '-v',
    ...fs.readdirSync(path.join(root, 'tests')).filter(name => /^core_.*_test\.go$/.test(name)).sort()
      .map(name => path.join(root, 'tests', name))], {
    cwd: path.join(root, 'proxy_core/src/flclash'), stdio: 'inherit', env: { ...process.env, GO111MODULE: 'on' }
  });
  if (result.error) console.error(result.error.message);
  process.exitCode = result.status ?? 1;
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
