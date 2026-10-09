import { ClashConfig, Sniffer, SnifferDefault, SNIFFER_DEFAULTS_VERSION } from './ClashConfig';

// Frozen v0 fingerprint: custom fields, explicit per-protocol overrides and disabled
// sniffing must not be mistaken for the old application default.
const LEGACY_SNIFFER: Sniffer = {
  enable: true,
  sniffing: [],
  'force-dns-mapping': true,
  'parse-pure-ip': true,
  'override-destination': false,
  'force-domain': ['+.v2ex.com'],
  'skip-domain': ['Mijia Cloud', '+.push.apple.com'],
  'skip-src-address': ['192.168.0.3/32'],
  'skip-dst-address': [
    '91.108.56.0/22', '91.108.4.0/22', '91.108.8.0/22', '91.108.16.0/22',
    '91.108.12.0/22', '149.154.160.0/20', '91.105.192.0/23', '91.108.20.0/22',
    '185.76.151.0/24', '2001:b28:f23d::/48', '2001:b28:f23f::/48',
    '2001:67c:4e8::/48', '2001:b28:f23c::/48', '2a0a:f280::/32'
  ],
  'port-whitelist': [],
  sniff: {
    HTTP: { ports: ['80', '8080-8880'], 'override-destination': true },
    TLS: { ports: ['443', '8443'] },
    QUIC: { ports: ['443', '8443'] }
  }
};

function sameSettings(left: Object, right: Object): boolean {
  if (left === right) return true;
  if (left === null || right === null || typeof left !== 'object' || typeof right !== 'object') return false;
  if (Array.isArray(left) !== Array.isArray(right)) return false;
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);
  if (leftKeys.length !== rightKeys.length) return false;
  return leftKeys.every(key => rightKeys.includes(key) &&
    sameSettings((left as Record<string, Object>)[key], (right as Record<string, Object>)[key]));
}

/** Migrate deserialized local settings once; callers persist the returned object. */
export function migrateSnifferConfig(config: ClashConfig): ClashConfig {
  if ((config.snifferDefaultsVersion ?? 0) >= SNIFFER_DEFAULTS_VERSION) return config;
  // snifferDefault is also persisted and is used as the compatibility page fallback.
  if (!config.snifferDefault || sameSettings(config.snifferDefault, LEGACY_SNIFFER)) {
    config.snifferDefault = new SnifferDefault();
  }
  if (!config.sniffer) {
    config.sniffer = config.snifferDefault;
  } else if (sameSettings(config.sniffer, LEGACY_SNIFFER)) {
    config.sniffer = new SnifferDefault();
  }
  // Mark even custom configurations, so a later user edit is never re-migrated.
  config.snifferDefaultsVersion = SNIFFER_DEFAULTS_VERSION;
  return config;
}
