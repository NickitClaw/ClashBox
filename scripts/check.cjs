#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const path = require('node:path');
process.chdir(path.resolve(__dirname, '..'));
const checks = [
  [process.execPath, ['scripts/generate-rpc.cjs', '--check']],
  [process.execPath, ['scripts/native-provenance.cjs', '--check', 'arm64-v8a']],
  [process.execPath, ['--test', 'tests/regression.cjs']],
  [process.env.GO_BIN || 'go', ['test', '-race', './proxy_core/src/flclash/rpcframe', './proxy_core/src/flclash/rpccontract']]
];
for (const [command, args] of checks) {
  const result = spawnSync(command, args, { stdio: 'inherit', env: { ...process.env, GO111MODULE: 'off' } });
  if (result.error) console.error(result.error.message);
  if (result.status !== 0) process.exit(result.status || 1);
}
