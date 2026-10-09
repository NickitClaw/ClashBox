import { UpdateConfigParams } from 'proxy_core/src/main/ets/models/ClashConfig';

export interface ConfigSnapshot {
  id: string;
  name: string;
  payload: UpdateConfigParams;
}

export interface ConfigActivationHost {
  selectedId: () => string;
  prepare: (id: string, update: boolean, patch: boolean, cancelled: () => boolean) => Promise<ConfigSnapshot>;
  apply: (snapshot: ConfigSnapshot) => Promise<void>;
  commit: (snapshot: ConfigSnapshot) => void;
  stop: () => Promise<void>;
}

/** All entry points share this queue. Only a confirmed, current operation publishes selection. */
export class ConfigActivationService {
  private queue: Promise<void> = Promise.resolve();
  private generation: number = 0;
  private confirmed?: ConfigSnapshot;
  private host: ConfigActivationHost;
  constructor(host: ConfigActivationHost) { this.host = host; }

  activate(id: string, update: boolean = false): Promise<boolean> {
    const generation = ++this.generation;
    return this.enqueue(() => this.run(id, update, false, generation));
  }

  reload(patch: boolean, expectedId?: string): Promise<boolean> {
    const generation = this.generation;
    // Resolve selection inside the queue, after any pending successful switch.
    return this.enqueue(() => {
      const id = this.host.selectedId();
      if (expectedId !== undefined && id !== expectedId) return Promise.resolve(false);
      return this.run(id, false, patch, generation);
    });
  }

  private enqueue(work: () => Promise<boolean>): Promise<boolean> {
    const pending = this.queue.then(work);
    this.queue = pending.then(() => {}, () => {});
    return pending;
  }

  private async restore(previous: ConfigSnapshot | undefined): Promise<void> {
    if (previous) {
      // A patch cannot restore the proxy/rule set replaced by a full switch.
      previous.payload.params['is-patch'] = false;
      await this.host.apply(previous);
    } else {
      await this.host.stop();
    }
  }

  private async run(id: string, update: boolean, patch: boolean, generation: number): Promise<boolean> {
    const cancelled = (): boolean => generation !== this.generation;
    if (cancelled() || id === '') return false;
    let snapshot: ConfigSnapshot;
    try { snapshot = await this.host.prepare(id, update, patch, cancelled); } catch (e) {
      if (cancelled()) return false;
      throw e as Error;
    }
    if (cancelled()) return false;
    const previous = this.confirmed;
    if (patch && previous?.id === snapshot.id) {
      // A settings patch keeps the currently running proxy/rule source, even if the
      // subscription file was updated in the background since its activation.
      snapshot.payload.source = previous.payload.source;
    } else {
      snapshot.payload.params['is-patch'] = false;
    }
    try {
      await this.host.apply(snapshot);
      if (!cancelled()) {
        this.host.commit(snapshot);
        this.confirmed = snapshot;
        return true;
      }
    } catch (e) {
      await this.rollback(previous);
      if (cancelled()) return false;
      throw e as Error;
    }
    await this.rollback(previous);
    return false;
  }

  private async rollback(previous: ConfigSnapshot | undefined): Promise<void> {
    try { await this.restore(previous); } catch (_) {
      this.confirmed = undefined;
      try { await this.host.stop(); } catch (_) {
        throw new Error('配置恢复失败，且无法确认 VPN 已停止，请重新启动应用');
      }
      throw new Error('配置恢复失败，VPN 已停止，请重新加载配置');
    }
  }
}
