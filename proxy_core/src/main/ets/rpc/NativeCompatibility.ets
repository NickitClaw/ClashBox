import * as nativeCore from 'libflclash.so';
import { assertRpcCompatibility, RpcError } from './RpcContract';
import { RpcCapabilities, RpcErrorCode } from './RpcContract.generated';

/** Namespace lookup permits a clear diagnostic even when an older .so lacks the export. */
export function assertNativeCompatibility(): RpcCapabilities {
  if (typeof nativeCore.getCompatibilityInfo !== 'function') {
    throw new RpcError(RpcErrorCode.INCOMPATIBLE_VERSION, '原生内核缺少兼容性接口，请更新完整应用包');
  }
  return assertRpcCompatibility(nativeCore.getCompatibilityInfo());
}
