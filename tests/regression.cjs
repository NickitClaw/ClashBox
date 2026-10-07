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
function profileFixture() {
  const files = new Map(), handles = new Map(), locks = new Map(); let fd = 0;
  const io = { OpenMode: {}, AccessModeType: {},
    open: async p => { const id = ++fd; handles.set(id, { path: p, offset: 0 }); if (!files.has(p)) files.set(p, '');
      return { fd: id,
        tryLock: () => { if (locks.has(p)) { const e = new Error('busy'); e.code = 13900034; throw e; } locks.set(p, true); },
        unlock: () => locks.delete(p)
      }; },
    write: async (id, bytes) => { const h = handles.get(id); const chunk = Buffer.from(bytes); files.set(h.path, files.get(h.path) + chunk.toString()); return chunk.length; },
    close: async id => { handles.delete(id); }, fsync: async () => {},
    rename: async (src, dst) => { assert.ok(files.has(src)); files.set(dst, files.get(src)); files.delete(src); },
    unlink: async p => { if (!files.delete(p)) throw new Error('ENOENT'); }
  };
  const { Profile } = load('proxy_core/src/main/ets/Profile.ets', {
    '@ohos.file.fs': { default: io }, './appPath': { getProfilePath: async (_, id) => '/profiles/' + id, getProfilesPath: async () => '/profiles' },
    '@kit.ArkTS': { JSON, util, taskpool: { Task: class { constructor(fn, raw) { this.raw = raw; } }, execute: async t => t.raw } }
  });
  const create = id => { const p = new Profile(1, ''); p.id = id; p.context = { tempDir: '/temp' }; return p; };
  return { files, handles, create };
}
test('Concurrent profile saves validate and commit their own bytes atomically', async () => {
  const f = profileFixture(), gate = deferred(), entered = deferred();
  f.files.set('/profiles/A', 'previous');
  const a = f.create('A').save('invalid-A', async p => { entered.resolve(); await gate.promise; assert.equal(f.files.get(p), 'invalid-A'); return 'invalid'; });
  await entered.promise;
  await f.create('B').save('valid-B', async p => { assert.equal(f.files.get(p), 'valid-B'); return ''; });
  assert.equal(f.files.get('/profiles/A'), 'previous'); gate.resolve(); await assert.rejects(a, /invalid/);
  assert.equal(f.files.get('/profiles/A'), 'previous'); assert.equal(f.files.get('/profiles/B'), 'valid-B');
  assert.equal(f.handles.size, 0); assert.ok(![...f.files.keys()].some(p => p.endsWith('.tmp')));
});
test('Same profile writers serialize; cancellation during validation leaves prior file intact', async () => {
  const f = profileFixture(), gate = deferred(), entered = deferred(); let secondEntered = false;
  const a = f.create('A').save('first', async () => { entered.resolve(); await gate.promise; return ''; }); await entered.promise;
  const b = f.create('A').save('second', async () => { secondEntered = true; return ''; }); await flush();
  assert.equal(secondEntered, false); gate.resolve(); await Promise.all([a, b]); assert.equal(f.files.get('/profiles/A'), 'second');
  let cancelled = false; const c = f.create('A'); c.shouldCancelUpdate = () => cancelled;
  await assert.rejects(c.save('cancelled', async () => { cancelled = true; return ''; }), /取消/);
  assert.equal(f.files.get('/profiles/A'), 'second'); assert.equal(f.handles.size, 0);
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
