#!/usr/bin/env node
// Optional native integration check: requires initialized core submodules and Go dependencies.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');
const { createCoreOverlay } = require('../proxy_core/src/flclash/corepatches/overlay.cjs');
function load(file, imports) {
  const module = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, require: name => imports[name] });
  return module.exports;
}
const model = load('proxy_core/src/main/ets/models/ClashConfig.ts', {
  './Common': { LogLevel: { Info: 'info' }, ProxyMode: { Rule: 'rule' } }
});
const { migrateSnifferConfig } = load('proxy_core/src/main/ets/models/SnifferMigration.ts', { './ClashConfig': model });
const legacy = JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/legacy-sniffer.json'), 'utf8'));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'clashbox-sniffer-'));
try {
  const fixtures = path.join(temp, 'settings.json');
  fs.writeFileSync(fixtures, JSON.stringify({ legacy, fresh: new model.ClashConfig().sniffer,
    migrated: migrateSnifferConfig({ sniffer: structuredClone(legacy) }).sniffer }));
  const result = spawnSync(process.env.GO_BIN || 'go', ['test', '-mod=readonly', '-race', '-overlay', createCoreOverlay(temp), '-v',
    path.join(root, 'tests/sniffer_destination_test.go')], {
    cwd: path.join(root, 'proxy_core/src/flclash'), stdio: 'inherit',
    env: { ...process.env, GO111MODULE: 'on', CLASHBOX_SNIFFER_FIXTURES: fixtures }
  });
  if (result.error) console.error(result.error.message);
  process.exitCode = result.status ?? 1;
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
