#!/usr/bin/env node
// Works in CI without SDK or submodule checkouts. Hashes source bytes plus pinned gitlinks.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function sourceDigest() {
  const prefix = 'proxy_core/src/flclash';
  const paths = git('ls-files', '--cached', '--others', '--exclude-standard', '--', prefix, 'protocol/rpc.schema.json', '.gitmodules')
    .split('\n').filter(Boolean);
  const links = new Map(git('ls-files', '--stage', '--', prefix).split('\n').filter(line => line.startsWith('160000 '))
    .map(line => { const [info, name] = line.split('\t'); return [name, info.split(' ')[1]]; }));
  const digest = crypto.createHash('sha256');
  for (const name of [...new Set(paths)].sort()) {
    if (name.endsWith('.so') || name.endsWith('.a')) continue;
    digest.update(name + '\0');
    digest.update(links.get(name) || fs.readFileSync(path.join(root, name)));
    digest.update('\0');
  }
  return { digest: digest.digest('hex'), submodules: Object.fromEntries(links) };
}
function verify(arch) {
  const base = path.join(root, 'proxy_core/libs', arch);
  const info = JSON.parse(fs.readFileSync(path.join(base, 'libflclash.build.json'), 'utf8'));
  const binary = fs.readFileSync(path.join(base, 'libflclash.so'));
  const source = sourceDigest();
  if (source.digest !== info.sourceDigest) throw new Error('Native sources changed: rebuild libflclash.so with build.sh');
  if (sha(binary) !== info.binarySHA256) throw new Error('Native binary does not match its build manifest');
  if (!binary.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]))) throw new Error('Native library is not ELF');
  const contract = fs.readFileSync(path.join(root, 'proxy_core/src/flclash/rpccontract/schema_generated.go'), 'utf8')
    .match(/const ContractHash = "([a-f0-9]+)"/)[1];
  if (contract !== info.contractHash || !binary.includes(Buffer.from(contract))) throw new Error('Native RPC contract mismatch');
  return info;
}
function write(arch, go) {
  const source = sourceDigest();
  for (const [name, revision] of Object.entries(source.submodules)) {
    if (git('-C', name, 'rev-parse', 'HEAD') !== revision || git('-C', name, 'status', '--porcelain') !== '') {
      throw new Error(`Native submodule must match its clean pinned revision: ${name}`);
    }
  }
  const base = path.join(root, 'proxy_core/libs', arch);
  const binary = fs.readFileSync(path.join(base, 'libflclash.so'));
  const contractHash = fs.readFileSync(path.join(root, 'proxy_core/src/flclash/rpccontract/schema_generated.go'), 'utf8')
    .match(/const ContractHash = "([a-f0-9]+)"/)[1];
  const nativeHome = process.env.OHOS_NATIVE_HOME || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native';
  const sdk = JSON.parse(fs.readFileSync(path.join(nativeHome, 'oh-uni-package.json'), 'utf8'));
  const info = { architecture: arch, builtAt: new Date().toISOString(), sourceCommit: git('rev-parse', 'HEAD'),
    sourceDigest: source.digest, submodules: source.submodules, contractHash, binarySHA256: sha(binary),
    go: execFileSync(go, ['version'], { encoding: 'utf8' }).trim(),
    clang: execFileSync(path.join(nativeHome, 'llvm/bin/clang'), ['--version'], { encoding: 'utf8' }).trim(), sdk };
  fs.writeFileSync(path.join(base, 'libflclash.build.json'), JSON.stringify(info, null, 2) + '\n');
  verify(arch);
}
if (require.main === module) {
  try {
    const [mode, arch = 'arm64-v8a', go] = process.argv.slice(2);
    if (!['arm64-v8a', 'x86_64'].includes(arch)) throw new Error('Unsupported architecture');
    if (mode === '--write' && go) write(arch, go);
    else if (mode === '--check') verify(arch);
    else throw new Error('Usage: native-provenance.cjs --check ARCH | --write ARCH GO_BINARY');
    console.log(`Native source/binary verification passed (${arch})`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { sourceDigest, verify, sha };
