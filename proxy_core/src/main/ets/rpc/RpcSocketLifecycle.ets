import { socket } from '@kit.NetworkKit';

// One request per connection. After a complete response (or on cancellation),
// ACK asks the server to close first. LocalSocket's detached poll/recv thread
// must see EOF before its descriptor can be reused by another request.
export const RPC_RESPONSE_RECEIPT: number = 0x06;

export function closeRpcSocket(client: socket.LocalSocket): void {
  try { client.off('message') } catch (_) {}
  try { client.off('error') } catch (_) {}
  try { client.off('close') } catch (_) {}
  try { client.close().catch(() => {}) } catch (_) {}
}

export function releaseRpcSocket(client: socket.LocalSocket): void {
  let released = false;
  let timer = -1;
  const release = (): void => {
    if (released) return;
    released = true;
    clearTimeout(timer);
    closeRpcSocket(client);
  };
  try {
    client.off('message');
    client.off('error');
    client.off('close');
    client.on('close', release);
    client.on('error', release);
    // Servers bound response acknowledgement to 5 s. A broken peer must not
    // retain the descriptor forever; receiving a result remains a success.
    timer = setTimeout(release, 6000);
    client.send({ data: new Uint8Array([RPC_RESPONSE_RECEIPT]).buffer as ArrayBuffer })
      .catch(() => { release(); });
  } catch (_) { release(); }
}

export function isRpcReceipt(data: Uint8Array): boolean {
  return data.length === 1 && data[0] === RPC_RESPONSE_RECEIPT;
}
