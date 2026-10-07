import { util } from '@kit.ArkTS';

// Wire v2: uint32 big-endian UTF-8 byte length, followed by exactly that many bytes.
// One request per connection; one response or a sequence of framed log events.
export const MAX_RPC_FRAME_BYTES: number = 4 * 1024 * 1024;

export function encodeRpcFrame(json: string): ArrayBuffer {
  const bytes = new util.TextEncoder().encodeInto(json);
  if (bytes.length === 0 || bytes.length > MAX_RPC_FRAME_BYTES) throw new Error('RPC 帧长度超限');
  const frame = new Uint8Array(4 + bytes.length);
  new DataView(frame.buffer).setUint32(0, bytes.length, false);
  frame.set(bytes, 4);
  return frame.buffer as ArrayBuffer;
}

export class RpcFrameBuffer {
  private header: Uint8Array = new Uint8Array(4);
  private headerBytes: number = 0;
  private payload: Uint8Array = new Uint8Array(0);
  private payloadBytes: number = 0;

  push(chunk: Uint8Array): string[] {
    const frames: string[] = [];
    let offset = 0;
    while (offset < chunk.length) {
      if (this.headerBytes < 4) {
        const count = Math.min(4 - this.headerBytes, chunk.length - offset);
        this.header.set(chunk.subarray(offset, offset + count), this.headerBytes);
        this.headerBytes += count;
        offset += count;
        if (this.headerBytes < 4) break;
        const length = new DataView(this.header.buffer).getUint32(0, false);
        if (length === 0 || length > MAX_RPC_FRAME_BYTES) throw new Error('无效 RPC 帧长度');
        this.payload = new Uint8Array(length);
      }
      const count = Math.min(this.payload.length - this.payloadBytes, chunk.length - offset);
      this.payload.set(chunk.subarray(offset, offset + count), this.payloadBytes);
      this.payloadBytes += count;
      offset += count;
      if (this.payloadBytes === this.payload.length) {
        // Decode complete frames, never share a streaming decoder between connections.
        frames.push(new util.TextDecoder('utf-8', { fatal: true }).decodeToString(this.payload));
        this.headerBytes = 0;
        this.payloadBytes = 0;
        this.payload = new Uint8Array(0);
      }
    }
    return frames;
  }

  finish(): void {
    if (this.headerBytes !== 0) throw new Error('连接关闭时 RPC 帧不完整');
  }
}
