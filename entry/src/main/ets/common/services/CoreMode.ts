// Values are persisted in settings and backups; do not renumber them.
export enum ClashCore {
  mihomo = 0,
  ClashMeta = 1,
  ClashRs = 2,
}

export function resolveCoreMode(core: ClashCore | undefined, debug: boolean): ClashCore {
  // The foreground core is a debugging tool. Release builds always use the VPN extension.
  return debug && core === ClashCore.ClashMeta ? ClashCore.ClashMeta : ClashCore.mihomo;
}
