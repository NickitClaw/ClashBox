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
  if (process.exitCode === 0) {
    const wrapper = path.join(temp, 'wrapper');
    fs.mkdirSync(wrapper);
    const sources = ['common.go', 'hub.go', 'constant.go', 'config_snapshot.go'];
    for (const file of sources) fs.copyFileSync(path.join(root, 'proxy_core/src/flclash', file), path.join(wrapper, file));
    // Only the platform bridge and unused download entry point are stubbed.
    fs.writeFileSync(path.join(wrapper, 'bridge.go'), 'package main\nfunc sendMessage(message Message) {}\nfunc handleDownloadConfig(a,b,c string)(string,error){panic("unexpected platform download")}\n');
    fs.copyFileSync(path.join(root, 'tests/wrapper_config_test.go'), path.join(wrapper, 'config_test.go'));
    const wrapperResult = spawnSync(process.env.GO_BIN || 'go', ['test', '-mod=readonly', '-race', '-overlay', overlay, '-v',
      ...[...sources, 'bridge.go', 'config_test.go'].map(name => path.join(wrapper, name))], {
      cwd: path.join(root, 'proxy_core/src/flclash'), stdio: 'inherit', env: { ...process.env, GO111MODULE: 'on' }
    });
    if (wrapperResult.error) console.error(wrapperResult.error.message);
    process.exitCode = wrapperResult.status ?? 1;
  }
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
