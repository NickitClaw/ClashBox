import { VpnPhase, VpnSnapshot } from './RpcContract.generated';

export function initialVpnState(phase: VpnPhase = VpnPhase.Stopped): VpnSnapshot {
  return { phase: phase, running: false, desiredRunning: false, startedAt: 0, generation: 0, error: '' };
}

/** Owned by the VPN service. The serialized operation queue is its only writer. */
export class VpnLifecycleState {
  private value: VpnSnapshot = initialVpnState();
  private observer?: (state: VpnSnapshot) => void;
  constructor(observer?: (state: VpnSnapshot) => void) { this.observer = observer; }
  private notify(): void {
    try { this.observer?.(this.snapshot()); } catch (_) { console.warn('VPN 状态投影失败'); }
  }
  snapshot(): VpnSnapshot {
    const state = this.value;
    return { phase: state.phase, running: state.running, desiredRunning: state.desiredRunning,
      startedAt: state.startedAt, generation: state.generation, error: state.error };
  }
  request(running: boolean): number {
    this.value.desiredRunning = running;
    this.value.generation++;
    if (!running) this.value.phase = VpnPhase.Stopping;
    else if (!this.value.running && this.value.phase !== VpnPhase.Stopping) this.value.phase = VpnPhase.Starting;
    this.notify();
    return this.value.generation;
  }
  move(phase: VpnPhase, error: string = ''): void {
    this.value.phase = phase;
    this.value.error = error;
    if (phase === VpnPhase.Stopping || phase === VpnPhase.Unknown) { this.notify(); return; }
    this.value.running = phase === VpnPhase.Running;
    this.value.startedAt = this.value.running ? Date.now() : 0;
    if (phase === VpnPhase.Failed) this.value.desiredRunning = false;
    this.notify();
  }
}

export function vpnStateLabel(phase: VpnPhase): string {
  switch (phase) {
    case VpnPhase.Starting: return '正在启动';
    case VpnPhase.Running: return '运行中';
    case VpnPhase.Stopping: return '正在停止';
    case VpnPhase.Recovering: return '正在恢复连接';
    case VpnPhase.Failed: return '连接失败，请重试';
    case VpnPhase.Unknown: return '暂时无法确认连接状态';
    default: return '已停止';
  }
}
