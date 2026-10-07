// Regression tests execute repository source with controlled HarmonyOS/native API doubles.
// Run: node --test tests/regression.cjs (after ohpm install and DevEco installation).
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.CLASHBOX_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const quiet = { log() {}, info() {}, warn() {}, error() {}, debug() {} };
class Decoder {
  constructor() { this.decoder = new TextDecoder(); }
  decodeToString(b, options) { return this.decoder.decode(b, options); }
  static create() { return new Decoder(); }
}
class Encoder { encodeInto(s) { return new TextEncoder().encode(s); } }
const util = { TextDecoder: Decoder, TextEncoder: Encoder, Base64Helper: class { decodeSync(s) { return Buffer.from(s, 'base64'); } } };
function clock() {
  let id = 0;
  const intervals = new Map(), timeouts = new Map();
  return { intervals, timeouts,
    setInterval(fn) { intervals.set(++id, fn); return id; },
    clearInterval(n) { intervals.delete(n); },
    setTimeout(fn) { timeouts.set(++id, fn); return id; },
    clearTimeout(n) { timeouts.delete(n); }
  };
}
function load(file, mocks = {}, globals = {}, source) {
  const input = (source ?? fs.readFileSync(path.join(root, file), 'utf8')).replace(/^\s*@Concurrent\s*$/gm, '');
  const result = ts.transpileModule(input, { fileName: file.replace(/\.ets$/, '.ts'), compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true, useDefineForClassFields: false
  }, reportDiagnostics: true });
  const syntaxErrors = (result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(syntaxErrors.length, 0, JSON.stringify(syntaxErrors.map(d => d.messageText)));
  const module = { exports: {} };
  const context = { module, exports: module.exports, require: name => mocks[name] ?? {},
    console: quiet, setTimeout, clearTimeout, setInterval, clearInterval,
    ObservedV2: x => x, Observed: x => x, Trace() {}, JSON, ...globals };
  vm.runInNewContext(result.outputText, context, { filename: file, timeout: 5000 });
  return module.exports;
}
function noticeFixture(enabled = true, permission = () => Promise.resolve(true)) {
  const time = clock(), actions = [];
  const prefs = { enabledNotice: enabled, permanentNotice: true, statusNotice: false, backgrounder: false, coexistNotice: false, proxyName: 'test' };
  const mod = load('proxy_core/src/main/ets/rpc/VpnNoticeController.ets', {
    '@kit.NotificationKit': { notificationManager: {
      isNotificationEnabled: permission, SlotType: {}, ContentType: {},
      publish: async () => { actions.push('publish'); }, cancel: async () => { actions.push('cancel'); }
    } },
    '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => ({}), OperationType: {}, WantAgentFlags: {} } },
    '@kit.ArkTS': { JSON }, 'libflclash.so': { getTraffic: () => '{"up":0,"down":0}' },
    '../models/Common': { Traffic: class { constructor(up, down) { this.up = up; this.down = down; } } },
    './VpnNoticeStore': { readVpnNoticePrefs: () => prefs, shouldPublishVpnNotice: p => p.enabledNotice && p.permanentNotice && (!p.backgrounder || p.coexistNotice) }
  }, time);
  return { instance: new mod.VpnNoticeController({ applicationInfo: { name: 'review' } }), time, prefs, actions };
}
const yaml = require(path.join(root, 'oh_modules/yaml/dist/index.js'));
const { YamlUtils } = load('proxy_core/src/main/ets/utils/YamlUtils.ts', { yaml, '@kit.ArkTS': { util } });
const rpcFrames = load('proxy_core/src/main/ets/rpc/RpcFrame.ets', { '@kit.ArkTS': { util } });
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const nodeOf = uri => yaml.parse(YamlUtils.convertUniversalToClashYaml(uri)).proxies[0];

test('SS SIP002, legacy and IPv6 preserve real credentials and names', () => {
  const auth = 'aes-256-gcm:p:a密钥';
  const links = [
    `ss://${Buffer.from(auth).toString('base64url')}@[2001:db8::1]:8443#测试`,
    `ss://${Buffer.from(auth + '@[2001:db8::1]:8443').toString('base64')}#测试`,
    `ss://aes-256-gcm:${encodeURIComponent('p:a密钥')}@[2001:db8::1]:8443#测试`
  ];
  for (const uri of links) {
    const node = nodeOf(uri);
    assert.equal(node.server, '2001:db8::1'); assert.equal(node.port, 8443);
    assert.equal(node.password, 'p:a密钥'); assert.equal(node.name, '测试'); assert.equal(node.cipher, 'aes-256-gcm');
  }
});
test('Trojan TLS, websocket and gRPC options survive import', () => {
  const n = nodeOf('trojan://p%40ss%3A%E5%AF%86@host.invalid:443?sni=tls.invalid&type=ws&host=cdn.invalid&path=%2Fws#Node');
  assert.equal(n.password, 'p@ss:密'); assert.equal(n.server, 'host.invalid');
  assert.equal(n.sni, 'tls.invalid'); assert.equal(n['skip-cert-verify'], false);
  assert.equal(n['ws-opts'].path, '/ws'); assert.equal(n['ws-opts'].headers.Host, 'cdn.invalid');
  const grpc = nodeOf('trojan://test@[::1]:443?type=grpc&serviceName=service&allowInsecure=1');
  assert.equal(grpc['grpc-opts']['grpc-service-name'], 'service'); assert.equal(grpc['skip-cert-verify'], true);
});
test('Malformed and unsupported SS/Trojan links fail explicitly', () => {
  for (const uri of ['ss://broken', 'ss://aes-256-gcm:test@host:0', 'trojan://test@host:65536',
    'ss://aes-256-gcm:test@host:443?plugin=unsupported', 'trojan://test@host:443?type=kcp',
    'trojan://test@host:443?allowInsecure=maybe', 'trojan://test@host:443?security=none']) {
    assert.throws(() => nodeOf(uri));
  }
});
test('Invalid YAML is attempted once; overflowing credential scalars remain strings', () => {
  let attempts = 0;
  const counted = { ...yaml, parseDocument: (...args) => { attempts++; return yaml.parseDocument(...args); } };
  const { YamlUtils: parser } = load('proxy_core/src/main/ets/utils/YamlUtils.ts', { yaml: counted, '@kit.ArkTS': { util } });
  for (const invalid of ['key: *missingAnchor', 'key: [unterminated']) {
    attempts = 0; assert.throws(() => parser.parseYamlSafe(invalid), e => e.name !== 'RangeError'); assert.equal(attempts, 1);
  }
  assert.equal(parser.parseYamlSafe('password: 48654786e0504509').password, '48654786e0504509');
});
test('Existing SSR conversion keeps IPv6, remarks and protocol parameters', () => {
  const b64 = s => Buffer.from(s).toString('base64url');
  const n = nodeOf('ssr://' + b64(`2001:db8::1:443:auth_sha1_v4:aes-128-cfb:tls1.2_ticket_auth:${b64('test-password')}/?remarks=${b64('测试节点')}&protoparam=${b64('param')}`));
  assert.equal(n.server, '2001:db8::1'); assert.equal(n.name, '测试节点'); assert.equal(n.password, 'test-password');
  assert.equal(n['protocol-param'], 'param');
});
test('Notification stop wins over delayed permission/publish; no timer resurrection', async () => {
  const gate = deferred(); const f = noticeFixture(true, () => gate.promise);
  const starting = f.instance.start(); await flush(); const stopping = f.instance.stop();
  gate.resolve(true); await Promise.all([starting, stopping]);
  assert.equal(f.time.intervals.size, 0); assert.equal(f.actions.at(-1), 'cancel');
  assert.ok(!f.actions.includes('publish'));
});
test('Notifications observe disabled-to-enabled changes while the VPN remains active', async () => {
  const f = noticeFixture(false); await f.instance.start(); assert.equal(f.time.intervals.size, 1);
  f.prefs.enabledNotice = true; f.instance.tick(); await flush(); assert.equal(f.actions.at(-1), 'publish');
  f.prefs.enabledNotice = false; f.instance.tick(); await flush(); assert.equal(f.actions.at(-1), 'cancel');
  f.prefs.enabledNotice = true; f.instance.tick(); await flush(); assert.equal(f.actions.at(-1), 'publish');
  await f.instance.stop(); assert.equal(f.time.intervals.size, 0);
});
test('Binary RPC frames survive every split, coalescing, UTF-8 and embedded EOF', () => {
  const a = Buffer.from(rpcFrames.encodeRpcFrame(JSON.stringify({ result: '节点 EOF 😀' })));
  const b = Buffer.from(rpcFrames.encodeRpcFrame(JSON.stringify({ result: 'next' })));
  const data = Buffer.concat([a, b]);
  for (let split = 0; split <= data.length; split++) {
    const decoder = new rpcFrames.RpcFrameBuffer();
    const frames = [...decoder.push(data.subarray(0, split)), ...decoder.push(data.subarray(split))];
    assert.equal(frames.length, 2); assert.equal(JSON.parse(frames[0]).result, '节点 EOF 😀'); decoder.finish();
  }
  const partial = new rpcFrames.RpcFrameBuffer(); partial.push(a.subarray(0, a.length - 1)); assert.throws(() => partial.finish());
  for (const size of [0, rpcFrames.MAX_RPC_FRAME_BYTES + 1]) {
    const header = Buffer.alloc(4); header.writeUInt32BE(size);
    assert.throws(() => new rpcFrames.RpcFrameBuffer().push(header));
  }
});
test('Concurrent RPC connections do not share UTF-8 state; send failures reject and close', async () => {
  const clients = [], time = clock(); let failSend = false;
  class Socket {
    constructor() { this.handlers = {}; this.closed = false; clients.push(this); }
    on(n, fn) { this.handlers[n] = fn; } off(n) { delete this.handlers[n]; }
    async connect() {} async send() { if (failSend) throw new Error('injected send failure'); }
    async close() { this.closed = true; }
    message(bytes) { const b = Uint8Array.from(bytes); this.handlers.message({ message: b.buffer }); }
  }
  const mod = load('proxy_core/src/main/ets/rpc/SocketProxyService.ets', {
    '@kit.NetworkKit': { socket: { constructLocalSocketInstance: () => new Socket() } },
    '@kit.ArkTS': { JSON, util }, '@kit.CoreFileKit': { fileIo: { access: async () => true } },
    './RpcFrame': rpcFrames, './IClashManager': { ClashRpcType: { startClash: 13, stopClash: 14 } }
  }, time);
  const service = new mod.SocketProxyService(); service.init({ filesDir: '/mock' });
  const a = service.sendMessageRequest(1), b = service.sendMessageRequest(2); await flush();
  const data = Buffer.from(rpcFrames.encodeRpcFrame('{"result":"节点"}')); const split = data.length - 3;
  clients[0].message(data.subarray(0, split)); clients[1].message(Buffer.from(rpcFrames.encodeRpcFrame('{"result":"OK"}')));
  clients[0].message(data.subarray(split)); assert.equal(await a, '节点'); assert.equal(await b, 'OK');
  assert.equal(time.timeouts.size, 0); assert.ok(clients.every(c => c.closed));
  failSend = true; await assert.rejects(service.sendMessageRequest(1), /injected send failure/);
  assert.ok(clients.at(-1).closed);
});
function profileFixture({ passthrough = false } = {}) {
  const data = new Map(), handles = new Map(), locks = new Map(); let fd = 0;
  const faults = { readBytes: Infinity, writeBytes: Infinity, write: false, read: false, rename: false };
  const configPath = id => `/profiles/${id}/config.yaml`;
  // Expose text for assertions, while the fake OS stores bytes (including partial UTF-8 writes).
  const files = { set: (p, text) => data.set(p, Buffer.from(text)), get: p => data.get(p)?.toString('utf8'),
    keys: () => data.keys(), has: p => data.has(p), delete: p => data.delete(p) };
  const io = { OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 }, AccessModeType: {},
    open: async (p, mode) => {
      if (!data.has(p) && !(mode & 64)) throw new Error('ENOENT');
      if (!data.has(p) || (mode & 512)) data.set(p, Buffer.alloc(0));
      const id = ++fd; handles.set(id, { path: p, offset: 0 });
      return { fd: id,
        tryLock: () => { if (locks.has(p)) { const e = new Error('busy'); e.code = 13900034; throw e; } locks.set(p, true); },
        unlock: () => locks.delete(p)
      };
    },
    access: async p => data.has(p),
    stat: async id => ({ size: data.get(handles.get(id).path).length }),
    read: async (id, buffer) => {
      if (faults.read) throw new Error('injected read failure');
      const h = handles.get(id), src = data.get(h.path);
      const n = Math.min(buffer.byteLength, src.length - h.offset, faults.readBytes);
      new Uint8Array(buffer).set(src.subarray(h.offset, h.offset + n)); h.offset += n; return n;
    },
    write: async (id, bytes) => {
      if (faults.write) throw new Error('injected write failure');
      const h = handles.get(id), old = data.get(h.path), src = Buffer.from(bytes);
      const n = Math.min(src.length, faults.writeBytes), dest = Buffer.alloc(Math.max(old.length, h.offset + n));
      old.copy(dest); src.copy(dest, h.offset, 0, n); h.offset += n; data.set(h.path, dest); return n;
    },
    close: async id => { assert.ok(handles.delete(id)); }, fsync: async () => {},
    rename: async (src, dst) => {
      if (faults.rename && dst.endsWith('/config.yaml')) throw new Error('injected rename failure');
      assert.ok(data.has(src)); data.set(dst, data.get(src)); data.delete(src);
    },
    unlink: async p => { if (!data.delete(p)) throw new Error('ENOENT'); },
    listFile: async () => ['config.yaml']
  };
  const ark = { JSON, util, taskpool: {
    Task: class { constructor(fn, ...args) { this.fn = fn; this.args = args; } },
    execute: async t => passthrough ? t.args[0] : t.fn(...t.args)
  } };
  const storage = load('proxy_core/src/main/ets/profile/ProfileStorage.ets', {
    '@ohos.file.fs': { default: io }, '@kit.ArkTS': ark,
    '../appPath': { getProfilePath: async (_, id) => configPath(id), getProfilesPath: async () => '/profiles' }
  });
  const yamlUtil = load('proxy_core/src/main/ets/utils/YamlUtil.ets', { yaml, './YamlUtils': { YamlUtils },
    './ScriptExecutor': { ScriptExecutor: { execute: (script, input, name) => {
      return vm.runInNewContext(`${script}; JSON.stringify(main(JSON.parse(input), name))`, { input, name }, { timeout: 1000 });
    } } }
  });
  const transformer = load('proxy_core/src/main/ets/profile/ProfileTransformer.ets', {
    '@kit.ArkTS': ark, '../utils/YamlUtils': { YamlUtils }, '../utils/YamlUtil': yamlUtil
  });
  const network = { response: { responseCode: 200, result: '', header: {} }, destroys: 0, requests: 0 };
  const downloader = load('proxy_core/src/main/ets/profile/ProfileDownloader.ets', {
    '@ohos.file.fs': { default: io }, '@kit.ArkTS': ark, './ProfileStorage': storage,
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, createHttp: () => ({
      request: async () => { network.requests++; return network.response; }, destroy: () => network.destroys++
    }) } }
  });
  const { Profile } = load('proxy_core/src/main/ets/Profile.ets', {
    '@ohos.file.fs': { default: io }, './appPath': { getProfilePath: async (_, id) => configPath(id), getProfilesPath: async () => '/profiles' },
    './profile/ProfileStorage': storage, './profile/ProfileTransformer': transformer, './profile/ProfileDownloader': downloader,
    './models/Common': { SubscriptionInfo: { formHString: v => ({ raw: v }) } }, './utils/YamlUtils': { YamlUtils }
  });
  const create = id => { const p = new Profile(1, ''); p.id = id; p.context = { tempDir: '/temp', filesDir: '/files' }; return p; };
  const clean = () => { assert.equal(handles.size, 0); assert.equal(locks.size, 0); assert.ok(![...data.keys()].some(p => p.endsWith('.tmp'))); };
  return { files, handles, create, configPath, faults, network, storage, transformer, clean };
}
test('Concurrent profile saves validate and commit their own bytes atomically', async () => {
  const f = profileFixture({ passthrough: true }), gate = deferred(), entered = deferred();
  f.files.set('/profiles/A/config.yaml', 'previous');
  const a = f.create('A').save('invalid-A', async p => { entered.resolve(); await gate.promise; assert.equal(f.files.get(p), 'invalid-A'); return 'invalid'; });
  await entered.promise;
  await f.create('B').save('valid-B', async p => { assert.equal(f.files.get(p), 'valid-B'); return ''; });
  assert.equal(f.files.get('/profiles/A/config.yaml'), 'previous'); gate.resolve(); await assert.rejects(a, /invalid/);
  assert.equal(f.files.get('/profiles/A/config.yaml'), 'previous'); assert.equal(f.files.get('/profiles/B/config.yaml'), 'valid-B');
  assert.equal(f.handles.size, 0); assert.ok(![...f.files.keys()].some(p => p.endsWith('.tmp')));
});
test('Same profile writers serialize; cancellation during validation leaves prior file intact', async () => {
  const f = profileFixture({ passthrough: true }), gate = deferred(), entered = deferred(); let secondEntered = false;
  const a = f.create('A').save('first', async () => { entered.resolve(); await gate.promise; return ''; }); await entered.promise;
  const b = f.create('A').save('second', async () => { secondEntered = true; return ''; }); await flush();
  assert.equal(secondEntered, false); gate.resolve(); await Promise.all([a, b]); assert.equal(f.files.get('/profiles/A/config.yaml'), 'second');
  let cancelled = false; const c = f.create('A'); c.shouldCancelUpdate = () => cancelled;
  await assert.rejects(c.save('cancelled', async () => { cancelled = true; return ''; }), /取消/);
  assert.equal(f.files.get('/profiles/A/config.yaml'), 'second'); assert.equal(f.handles.size, 0);
});
const profileYaml = 'proxies: []\nproxy-providers:\n  example:\n    type: http\n    url: https://example.invalid/nodes\nrules:\n  - MATCH,DIRECT\n';
const editRule = 'DOMAIN,example.invalid,DIRECT';
const incrementScript = 'function main(config) { config.counter = (config.counter || 0) + 1; return config; }';

test('URI imports use real conversion and validate the exact committed bytes, including short UTF-8 IO', async () => {
  const f = profileFixture(), p = f.create('A'); f.faults.readBytes = 3; f.faults.writeBytes = 2;
  const uri = 'file://selected/nodes';
  f.files.set(uri, 'trojan://p%40ss@host.invalid:443#测试节点');
  f.files.set(f.configPath('A'), profileYaml);
  let validated;
  await p.saveByUri(uri, async path => {
    validated = f.files.get(path); const node = yaml.parse(validated).proxies[0];
    assert.equal(node.name, '测试节点'); assert.equal(node.password, 'p@ss'); assert.equal(node.server, 'host.invalid'); return '';
  });
  assert.equal(f.files.get(f.configPath('A')), validated); f.clean();
});

test('Subscription updates and local imports produce the same configuration through the same pipeline', async () => {
  const f = profileFixture(), a = f.create('A'), b = f.create('B');
  const link = 'ss://aes-256-gcm:secret@host.invalid:443#node'; // Valid subscriptions can be < 200 bytes.
  const options = 'mode: global'; a.yamlOverride = options; b.yamlOverride = options;
  f.files.set('/source', link); a.url = 'https://example.invalid/sub';
  await a.update({ downloadConfig: async (_, __, path) => {
    f.files.set(path, link); return JSON.stringify({ 'content-disposition': 'attachment; filename="test"', 'subscription-userinfo': 'upload=1' });
  }, vailConfig: async () => '' }, [editRule]);
  await b.saveByUri('/source', async () => '', [editRule]);
  assert.equal(f.files.get(f.configPath('A')), f.files.get(f.configPath('B')));
  assert.equal(a.name, 'test'); assert.equal(a.subscriptionInfo.raw, 'upload=1');
  assert.ok(![...f.files.keys()].some(p => p.startsWith('/temp/'))); f.clean();
});

test('Failed subscription validation preserves both committed configuration and metadata', async () => {
  const f = profileFixture(), p = f.create('A'); p.name = 'previous'; p.lastUpdateDate = 123;
  p.subscriptionInfo = { raw: 'previous' }; f.files.set(f.configPath('A'), profileYaml);
  await assert.rejects(p.update({ downloadConfig: async (_, __, path) => {
    f.files.set(path, profileYaml); return JSON.stringify({ 'content-disposition': 'attachment; filename="new"', 'subscription-userinfo': 'new' });
  }, vailConfig: async () => 'rejected' }), /rejected/);
  assert.equal(p.name, 'previous'); assert.equal(p.lastUpdateDate, 123); assert.equal(p.subscriptionInfo.raw, 'previous');
  assert.equal(f.files.get(f.configPath('A')), profileYaml); f.clean();
});

test('HTTP fallback completes partial writes, closes the request and removes its temporary file', async () => {
  const f = profileFixture(), p = f.create('A'); f.faults.writeBytes = 3;
  f.network.response.result = profileYaml; f.network.response.header = { 'Content-Disposition': 'attachment; filename="fallback"' };
  await p.update({ downloadConfig: async () => { throw new Error('native network error'); }, vailConfig: async () => '' });
  assert.equal(p.name, 'fallback'); assert.equal(f.network.requests, 1); assert.equal(f.network.destroys, 1);
  assert.ok(![...f.files.keys()].some(p => p.startsWith('/temp/'))); f.clean();
});

const writers = [
  ['save', (p, validate) => p.save(profileYaml, validate)],
  ['file import', (p, validate) => p.saveByUri('/source', validate)],
  ['manual edit', (p, validate) => p.saveEditedContent(profileYaml + 'mode: global\n', validate, profileYaml)],
  ['rule repair', (p, validate) => p.repairMissingRules(validate, [editRule])],
  ['rule reorder', (p, validate) => p.forceRewriteRules(validate, [editRule])],
  ['provider migration', (p, validate) => p.ensureProvidersLazy(validate)],
  ['script reapply', (p, validate) => p.reapplyScript(validate, incrementScript)],
  ['backup restore', (p, validate) => p.restoreScriptBackup(validate)]
];
for (const [name, operation] of writers) {
  test(`${name} rejects native validation errors without replacing the previous configuration`, async () => {
    const f = profileFixture(), p = f.create('A'), path = f.configPath('A');
    f.files.set(path, profileYaml); f.files.set('/source', profileYaml);
    if (name === 'backup restore') f.files.set('/profiles/A/config_script_backup.yaml', profileYaml);
    let calls = 0;
    await assert.rejects(operation(p, async temp => {
      calls++; assert.notEqual(temp, path); assert.ok(f.files.has(temp)); assert.equal(f.files.get(path), profileYaml); return 'invalid config';
    }), /invalid config/);
    assert.equal(calls, 1); assert.equal(f.files.get(path), profileYaml);
    assert.equal(f.files.has('/profiles/A/config_script_backup.yaml'), name === 'backup restore'); f.clean();
  });
}

test('Concurrent read-modify-write operations read the latest committed content under the same lock', async () => {
  const f = profileFixture(), p = f.create('A'), gate = deferred(), entered = deferred();
  f.files.set(f.configPath('A'), profileYaml);
  const first = p.save(profileYaml + 'marker: newer\n', async () => { entered.resolve(); await gate.promise; return ''; });
  await entered.promise;
  const second = f.create('A').forceRewriteRules(async () => '', [editRule]);
  gate.resolve(); await Promise.all([first, second]);
  const config = yaml.parse(f.files.get(f.configPath('A')));
  assert.equal(config.marker, 'newer'); assert.ok(config.rules.includes(editRule)); f.clean();
});

test('Manual editing preserves exact YAML text and rejects stale or deleted editor snapshots', async () => {
  const f = profileFixture(), p = f.create('A'), path = f.configPath('A'); f.files.set(path, profileYaml);
  const edit = '# keep comments and formatting\n' + profileYaml;
  let calls = 0;
  await p.saveEditedContent(edit, async temp => { calls++; assert.equal(f.files.get(temp), edit); return ''; }, profileYaml);
  assert.equal(f.files.get(path), edit);
  await assert.rejects(p.saveEditedContent('stale', async () => { calls++; return ''; }, profileYaml), /其他任务更新/);
  f.files.delete(path);
  await assert.rejects(p.saveEditedContent('deleted', async () => { calls++; return ''; }, edit), /已被删除/);
  assert.equal(calls, 1); assert.equal(f.files.has(path), false); f.clean();
});

test('Repeated script application uses its original backup and restore removes it only on success', async () => {
  const f = profileFixture(), p = f.create('A'), path = f.configPath('A'), backup = '/profiles/A/config_script_backup.yaml';
  f.files.set(path, profileYaml);
  await p.reapplyScript(async () => '', incrementScript);
  assert.equal(f.files.get(backup), profileYaml);
  await p.reapplyScript(async () => '', incrementScript);
  assert.equal(yaml.parse(f.files.get(path)).counter, 1);
  const scripted = f.files.get(path);
  await assert.rejects(p.restoreScriptBackup(async () => 'invalid restore'), /invalid restore/);
  assert.equal(f.files.get(path), scripted); assert.equal(f.files.get(backup), profileYaml);
  assert.equal(await p.restoreScriptBackup(async () => ''), true);
  assert.equal(yaml.parse(f.files.get(path)).counter, undefined); assert.equal(f.files.has(backup), false); f.clean();
});

test('Read, write, rename and zero-progress IO failures leave prior configuration and release locks', async () => {
  for (const fault of ['read', 'write', 'rename', 'zeroRead', 'zeroWrite']) {
    const f = profileFixture(), p = f.create('A'); f.files.set(f.configPath('A'), profileYaml); f.files.set('/source', profileYaml);
    if (fault === 'zeroRead') f.faults.readBytes = 0;
    else if (fault === 'zeroWrite') f.faults.writeBytes = 0;
    else f.faults[fault] = true;
    await assert.rejects(p.saveByUri('/source', async () => ''));
    assert.equal(f.files.get(f.configPath('A')), profileYaml); f.clean();
  }
  const f = profileFixture(), p = f.create('A'); f.files.set(f.configPath('A'), profileYaml); f.faults.rename = true;
  await assert.rejects(p.reapplyScript(async () => '', incrementScript), /rename failure/);
  assert.equal(f.files.has('/profiles/A/config_script_backup.yaml'), false); f.clean();
});

test('Cancellation after validation cancels script and migration writes without leaving a backup', async () => {
  for (const operation of [(p, v) => p.reapplyScript(v, incrementScript), (p, v) => p.ensureProvidersLazy(v)]) {
    const f = profileFixture(), p = f.create('A'); f.files.set(f.configPath('A'), profileYaml);
    let cancelled = false; p.shouldCancelUpdate = () => cancelled;
    await assert.rejects(operation(p, async () => { cancelled = true; return ''; }), /取消/);
    assert.equal(f.files.get(f.configPath('A')), profileYaml);
    assert.equal(f.files.has('/profiles/A/config_script_backup.yaml'), false); f.clean();
  }
});

test('Malformed overrides and failing scripts propagate before validation; identity scripts still apply rules', async () => {
  const f = profileFixture(), p = f.create('A'); f.files.set(f.configPath('A'), profileYaml);
  let calls = 0; const validate = async () => { calls++; return ''; };
  for (const bad of ['key: [', '- scalar', 'scalar']) {
    p.yamlOverride = bad; await assert.rejects(p.save(profileYaml, validate));
    assert.equal(f.files.get(f.configPath('A')), profileYaml);
  }
  p.yamlOverride = '';
  await assert.rejects(p.reapplyScript(validate, 'function main() { throw new Error("script failure"); }'), /script failure/);
  assert.equal(calls, 0);
  await p.reapplyScript(validate, 'function main(config) { return config; }', [editRule]);
  assert.ok(yaml.parse(f.files.get(f.configPath('A'))).rules.includes(editRule)); f.clean();
});

test('Rule repair examines actual YAML rules instead of matching comments or other fields', async () => {
  const f = profileFixture(), p = f.create('A');
  f.files.set(f.configPath('A'), `# ${editRule}\n${profileYaml}`);
  assert.equal(await p.repairMissingRules(async () => '', [editRule]), true);
  assert.equal(await p.repairMissingRules(async () => { throw new Error('unexpected write'); }, [editRule]), false);
  assert.equal(await p.ensureProvidersLazy(async () => { throw new Error('unexpected write'); }), false); f.clean();
});


test('Replacing or restoring a configuration rolls back obsolete backup retirement on rename failure', async () => {
  for (const operation of [(p, v) => p.saveEditedContent(profileYaml + 'mode: global\n', v, profileYaml),
    (p, v) => p.restoreScriptBackup(v)]) {
    const f = profileFixture(), p = f.create('A'), backup = '/profiles/A/config_script_backup.yaml';
    f.files.set(f.configPath('A'), profileYaml); f.files.set(backup, '# backup\n' + profileYaml); f.faults.rename = true;
    await assert.rejects(operation(p, async () => ''), /rename failure/);
    assert.equal(f.files.get(f.configPath('A')), profileYaml);
    assert.equal(f.files.get(backup), '# backup\n' + profileYaml); f.clean();
  }
});

test('The editor waits for commit, stays open on failure, and preserves later edits', async () => {
  const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/Configuration/EditConfigContent.ets'), 'utf8');
  const methods = src.slice(src.indexOf('  async saveConfigContent()'), src.indexOf('  // 配置是否保存弹框'));
  const errors = [], calls = [], closes = [], gate = deferred();
  let commit = async (...args) => { calls.push(args); await gate.promise; };
  const { Editor } = load('EditorFixture.ts', {
  }, { ClashViewModel: { saveProfileContent: (...args) => commit(...args) }, Xb_ToastUtil: { showToast: msg => errors.push(msg) } },
  `export class Editor { ${methods} }`);
  const e = new Editor();
  Object.assign(e, { savedContent: 'old', configStr: 'new', saving: false, currentTouchConfigData: { configId: 'A' },
    commManager: { sendCommand: async () => 'new' }, fileMenus: [], pageInfos: { pop: () => closes.push(true) } });
  const saving = e.saveAndClose(); await flush(); assert.equal(closes.length, 0);
  await e.saveAndClose(); assert.equal(calls.length, 1); // double-click cannot queue a duplicate write
  gate.resolve(); await saving; assert.equal(closes.length, 1);
  assert.deepEqual(calls[0], ['A', 'new', 'old']); assert.equal(e.configContentChange, false);
  e.configStr = 'failed'; e.commManager.sendCommand = async () => 'failed';
  commit = async () => { throw new Error('invalid YAML'); };
  await e.saveAndClose(); assert.equal(closes.length, 1); assert.equal(e.configContentChange, true);
  assert.equal(e.savedContent, 'new'); assert.match(errors[0].message, /invalid YAML/);
  const pending = deferred(); commit = async () => pending.promise;
  const later = e.saveAndClose(); await flush(); e.configStr = 'edited while saving'; pending.resolve(); await later;
  assert.equal(closes.length, 1); assert.equal(e.savedContent, 'failed'); assert.equal(e.configContentChange, true);
});

test('Same-length editor changes mark the draft dirty and undoing removes the save action', () => {
  const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/Configuration/EditConfigContent.ets'), 'utf8');
  const start = src.indexOf('    onContentChange:');
  const callback = src.slice(start, src.indexOf('    onEditingChange:', start));
  const { Editor } = load('EditorChangeFixture.ts', {}, {},
    `export class Editor { savedContent = 'mode: rule'; configStr = 'mode: rule'; fileMenus = []; saveMenus = {}; options = { ${callback} }; }`);
  const e = new Editor(); e.options.onContentChange('mode: glob');
  assert.equal(e.configContentChange, true); assert.equal(e.fileMenus.length, 1);
  e.options.onContentChange('mode: rule'); assert.equal(e.configContentChange, false); assert.equal(e.fileMenus.length, 0);
});


test('Result sets close on success, empty reads and mapping/rowCount failures', async () => {
  let opened = 0, closed = 0, rowCount = 1, failCount = false;
  const { ProfileRepo } = load('proxy_core/src/main/ets/ProfileRepo.ets', {
    '@kit.ArkData': { relationalStore: { RdbPredicates: class { equalTo() {} } } }, '@kit.ArkTS': { JSON }
  });
  const repo = new ProfileRepo(); repo.store = {
    query: async () => { opened++; return { get rowCount() { if (failCount) throw new Error('cursor failure'); return rowCount; }, goToNextRow() {}, close() { closed++; } }; },
    update: async () => {}, insert: async () => {}
  };
  repo.getFromCursor = () => ({ id: 'test' }); await repo.query('test'); rowCount = 0; await repo.query('none');
  await repo.addOrUpdate({ id: 'test', getSelectedMap: () => ({}) });
  rowCount = 1; repo.getFromCursor = () => { throw new Error('mapping failure'); }; await assert.rejects(repo.query('test'));
  failCount = true; await assert.rejects(repo.addOrUpdate({ id: 'test', getSelectedMap: () => ({}) }));
  assert.equal(closed, opened);
});
test('WebDAV debug logs and callbacks redact credentials, URLs and nested secret fields', () => {
  const messages = [], entries = [];
  const { WebDavLogger } = load('entry/src/main/ets/common/utils/webdav/logger.ts', {}, { console: { ...quiet, debug: m => messages.push(m) } });
  const logger = WebDavLogger.getInstance(); assert.equal(logger.getLevel(), 1); logger.setLevel('DEBUG'); logger.addCallback(e => entries.push(e));
  const auth = 'Basic ' + Buffer.from('test:secret').toString('base64');
  const data = { headers: { Authorization: auth, Cookie: 'cookie-secret' }, nested: { password: 'password-secret' }, url: 'https://user:pass@host/path?token=url-secret' };
  logger.debug('test', `Authorization: ${auth}`, data);
  const output = JSON.stringify({ messages, entries });
  for (const secret of [auth, 'cookie-secret', 'password-secret', 'url-secret', 'user:pass']) assert.ok(!output.includes(secret));
  assert.equal(data.headers.Authorization, auth); // logging must not mutate request headers
});
function vpnFixture({ failTun = false, stopGate } = {}) {
  const calls = [], time = clock(); let attempts = 0;
  const network = { vpnExtension: { createVpnConnection: () => ({
    create: async () => { attempts++; calls.push('create'); if (failTun) throw new Error('injected TUN failure'); return 7; },
    destroy: async () => calls.push('destroy'), protect: async () => {}
  }) } };
  const common = load('proxy_core/src/main/ets/rpc/CommonVpnService.ets', { '@kit.NetworkKit': network, './RpcFrame': rpcFrames });
  const mod = load('proxy_core/src/main/ets/rpc/FlClashVpnService.ets', {
    '@kit.NetworkKit': network, '@kit.ArkTS': { JSON, util }, './CommonVpnService': common, './RpcFrame': rpcFrames,
    './IClashManager': { ClashRpcType: { GetVersion: 33, GetVpnRunTime: 26 } },
    'libflclash.so': {
      stopTun: async () => { calls.push('stopTun'); if (stopGate) await stopGate.promise; calls.push('stopTunDone'); },
      startTun: async () => { calls.push('startTun'); return true; }, startIpc() {},
      startListener: () => calls.push('startListener'), stopListener: () => calls.push('stopListener')
    },
    './VpnNoticeController': { VpnNoticeController: class { async start() {} async stop() {} }, publishReconnectNotice: async () => calls.push('reconnectNotice') }
  }, { ...time, setTimeout: fn => { queueMicrotask(fn); return 1; } });
  const service = new mod.FlClashVpnService({ filesDir: '/mock/files' });
  service.ParseConfig = () => ({}); service.probeKernelRpc = async () => true;
  return { service, calls, time, get attempts() { return attempts; } };
}
test('Live IPC does not hide failed TUN recreation; retries end after three failures', async () => {
  const f = vpnFixture({ failTun: true }); f.service.desiredRunning = true; f.service.vpnActive = true;
  for (let i = 1; i <= 3; i++) {
    assert.equal(await f.service.healKernelInternal(), false);
    assert.equal(f.service.healFailures, i); assert.equal(f.service.vpnActive, false);
  }
  assert.equal(await f.service.healKernelInternal(), false);
  assert.equal(f.attempts, 3); assert.equal(f.service.desiredRunning, false);
  assert.ok(f.calls.includes('reconnectNotice')); assert.equal(f.time.intervals.size, 0);
});
test('VPN stop acknowledgement waits for native completion and precedes system destroy', async () => {
  const gate = deferred(); const f = vpnFixture({ stopGate: gate });
  f.service.vpnConnection = { destroy: async () => f.calls.push('destroy') };
  let complete = false; const stopping = f.service.stopVpn().then(() => { complete = true; });
  await flush(); assert.equal(complete, false); assert.ok(!f.calls.includes('destroy')); assert.ok(!f.calls.includes('stopListener'));
  gate.resolve(); await stopping;
  assert.ok(f.calls.indexOf('stopTunDone') < f.calls.indexOf('destroy'));
  assert.ok(f.calls.indexOf('destroy') < f.calls.indexOf('stopListener'));
});
test('User stop revokes a pending start and queued start never reports success', async () => {
  const gate = deferred(); const f = vpnFixture({ stopGate: gate });
  const starting = f.service.startVpn(); await flush(); const stopping = f.service.stopVpn();
  gate.resolve(); assert.equal(await starting, false); assert.equal(await stopping, true);
  assert.ok(!f.calls.includes('startTun')); assert.equal(f.service.vpnActive, false);
});
test('Reconnect notification is handled even when the UI running flag is stale', async () => {
  const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  const ast = ts.createSourceFile('EntryAbility.ts', src, ts.ScriptTarget.Latest, true);
  const cls = ast.statements.find(n => ts.isClassDeclaration(n));
  const method = cls.members.find(m => m.name?.getText(ast) === 'handleAutoReconnect').getText(ast);
  let starts = 0;
  const { Fixture } = load('ReconnectFixture.ts', {}, {
    ClashViewModel: { vpnStarted: true, RecoverVpn: async () => { starts++; } }, hilog: quiet
  }, `export class Fixture { clashCoreInitialized = true; autoReconnecting = false; ${method} }`);
  const f = new Fixture(); f.handleAutoReconnect({ parameters: { autoReconnect: true } });
  f.handleAutoReconnect({ parameters: { autoReconnect: true } }); await flush();
  assert.equal(starts, 1); assert.equal(f.autoReconnecting, false);
});
function viewModelFixture() {
  const calls = [], events = [];
  const { ClashViewModel } = load('entry/src/main/ets/entryability/ClashViewModel.ets', {
    'proxy_core/src/main/ets/ProfileRepo': { ProfileRepo: class {} },
    'proxy_core': { SocketProxyService: class {} },
    '../common/utils/HHmmssTimer': { Timer: class { reset() { calls.push('resetTimer'); } start() { calls.push('timer'); } } },
    '../common/EventHub': { EventHub: { sendEvent: e => events.push(e) }, EventKey: { StartedClash: 'started', StopedClash: 'stopped' } },
    '../common/utils/CardManageUtil': { cardManager: { pushCartProxyMode: state => calls.push(state ? 'runningCard' : 'stoppedCard'), pushCartVpnServiceTime() {} } },
    '../common/utils/VpnNoticeConfigSync': { syncVpnNoticePrefs: async () => {} },
    '@kit.PerformanceAnalysisKit': { hilog: quiet }
  });
  const service = new ClashViewModel(); service.loadConfig = async () => calls.push('loadConfig');
  service.loadVpnOptions = async () => calls.push('loadOptions');
  service.socketProxy.isSocketReady = async () => true;
  service.socketProxy.getRuntime = async () => 0;
  service.socketProxy.startClash = async () => { calls.push('start'); return true; };
  service.socketProxy.stopClash = async () => { calls.push('stop'); return true; };
  return { service, calls, events };
}
test('UI reports running only after start ack; rapid start-stop-start preserves last intent', async () => {
  const f = viewModelFixture(), gate = deferred(), entered = deferred();
  f.service.socketProxy.startClash = async () => { f.calls.push('start'); entered.resolve(); await gate.promise; return true; };
  const first = f.service.StartVpn(); await entered.promise; assert.equal(f.service.vpnStarted, false);
  const stop = f.service.StopVpn(); const last = f.service.StartVpn(); gate.resolve();
  await Promise.all([first, stop, last]);
  assert.equal(f.service.vpnStarted, true); assert.equal(f.service.desiredRunning, true);
  assert.ok(f.calls.indexOf('stop') < f.calls.lastIndexOf('start'));
});
test('Failed native start never starts duration timer or emits running state', async () => {
  const f = viewModelFixture(); f.service.socketProxy.startClash = async () => false;
  await assert.rejects(f.service.StartVpn(), /启动失败/);
  assert.equal(f.service.vpnStarted, false); assert.ok(!f.calls.includes('timer')); assert.ok(!f.events.includes('started'));
});

test('View model propagates editor validation failures and emits refresh only after commit', async () => {
  const f = viewModelFixture(), gate = deferred(), entered = deferred();
  f.service.context = { filesDir: '/files' };
  const args = [];
  f.service.getProfile = async () => ({
    loadContext: context => assert.equal(context, f.service.context),
    saveEditedContent: async (content, validate, expected) => {
      args.push([content, expected]); assert.equal(await validate('/staging'), ''); entered.resolve(); await gate.promise;
    }
  });
  f.service.socketProxy.vailConfig = async path => { assert.equal(path, '/staging'); return ''; };
  const saving = f.service.saveProfileContent('A', 'edited', 'original'); await entered.promise;
  assert.equal(f.events.length, 0); gate.resolve(); await saving; assert.equal(f.events.length, 1);
  assert.deepEqual(args[0], ['edited', 'original']);
  f.service.getProfile = async () => ({ loadContext() {}, saveEditedContent: async () => { throw new Error('validation failed'); } });
  await assert.rejects(f.service.saveProfileContent('A', 'bad', 'original'), /validation failed/);
  assert.equal(f.events.length, 1);
  f.service.getProfile = async () => null;
  await assert.rejects(f.service.saveProfileContent('A', 'gone', 'original'), /已被删除/);
});

test('Profile deletion awaits file transaction completion before deleting the database row', async () => {
  const f = viewModelFixture(), gate = deferred(), entered = deferred(); let removed = false;
  f.service.getProfile = async () => ({ loadContext() {}, delete: async () => { entered.resolve(); await gate.promise; } });
  f.service.profileRepo.delete = async () => { removed = true; };
  const deleting = f.service.deleteProfile('A'); await entered.promise; assert.equal(removed, false);
  gate.resolve(); await deleting; assert.equal(removed, true);
});
