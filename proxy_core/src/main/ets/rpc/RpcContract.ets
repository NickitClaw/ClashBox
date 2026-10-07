import { JSON } from '@kit.ArkTS';
import { RPC_PROTOCOL_VERSION, NATIVE_ABI_VERSION, RPC_CONTRACT_HASH, RPC_CAPABILITIES,
  RPC_METHODS, RpcErrorCode, RpcRequest, RpcResult, RpcShape, RpcMethodSpec, RpcValue,
  RpcCapabilities, ClashRpcType } from './RpcContract.generated';

export class RpcError extends Error {
  code: RpcErrorCode;
  method: number;
  constructor(code: RpcErrorCode, message: string, method: number = -1) {
    super(`${code}: ${message}`);
    this.code = code;
    this.method = method;
  }
}

export function rpcMethod(method: number): RpcMethodSpec {
  const spec = RPC_METHODS.find((item) => item.id === method);
  if (!spec) throw new RpcError(RpcErrorCode.UNKNOWN_METHOD, '未知 RPC 方法', method);
  return spec;
}

function matches(value: Object | null | undefined, shape: RpcShape): boolean {
  if (value === null) return shape.nullable === true;
  if (value === undefined) return false;
  switch (shape.type) {
    case 'boolean': return typeof value === 'boolean';
    case 'number':
    case 'integer': {
      if (typeof value !== 'number' || !Number.isFinite(value)) return false;
      if (shape.type === 'integer' && !Number.isSafeInteger(value)) return false;
      return (shape.min === undefined || value >= shape.min) && (shape.max === undefined || value <= shape.max);
    }
    case 'string':
    case 'decimalString': {
      if (typeof value !== 'string' || value.length < (shape.minLength ?? 0)) return false;
      if (shape.type === 'decimalString') return /^[0-9]+$/.test(value) && Number.isSafeInteger(Number(value));
      return !shape.enum || shape.enum.includes(value);
    }
    case 'json': {
      if (typeof value !== 'string' || !shape.content) return false;
      try { return matches(JSON.parse(value) as Object, shape.content); } catch (_) { return false; }
    }
    case 'array': {
      if (!Array.isArray(value) || !shape.items) return false;
      const items = value as Object[];
      for (const item of items) { if (!matches(item, shape.items)) return false; }
      return true;
    }
    case 'object': {
      if (typeof value !== 'object' || Array.isArray(value)) return false;
      const object = value as Record<string, Object>;
      for (const field of shape.fields ?? []) {
        if (object[field.name] === undefined && field.optional) continue;
        if (!matches(object[field.name], field.shape)) return false;
      }
      return true;
    }
  }
  return false;
}

export function createRpcRequest(method: number, params: RpcValue[] = [], endpoint: string = ''): RpcRequest {
  if (!Number.isSafeInteger(method)) throw new RpcError(RpcErrorCode.INVALID_REQUEST, 'method 必须是整数');
  const spec = rpcMethod(method);
  if (!spec.supported || (endpoint !== '' && spec.endpoint !== endpoint)) {
    throw new RpcError(RpcErrorCode.UNSUPPORTED_METHOD, '当前端点不支持此 RPC 方法', method);
  }
  if (!Array.isArray(params) || params.length > spec.params.length) {
    throw new RpcError(RpcErrorCode.INVALID_PARAMS, `${spec.arkName}: 参数数量错误`, method);
  }
  for (let i = 0; i < spec.params.length; i++) {
    const field = spec.params[i];
    if (i >= params.length && field.optional) continue;
    if (i >= params.length || !matches(params[i], field.shape)) {
      throw new RpcError(RpcErrorCode.INVALID_PARAMS, `${spec.arkName}: 参数 ${field.name} 缺失或类型错误`, method);
    }
  }
  return { protocolVersion: RPC_PROTOCOL_VERSION, method: method, params: params };
}

export function decodeRpcRequest(text: string, endpoint: string): RpcRequest {
  let raw: RpcRequest;
  try { raw = JSON.parse(text) as RpcRequest; } catch (_) {
    throw new RpcError(RpcErrorCode.INVALID_REQUEST, '请求不是有效 JSON');
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || !Number.isSafeInteger(raw.method)) {
    throw new RpcError(RpcErrorCode.INVALID_REQUEST, '请求必须包含整数 method');
  }
  if (raw.protocolVersion !== RPC_PROTOCOL_VERSION) {
    throw new RpcError(RpcErrorCode.INCOMPATIBLE_VERSION, 'RPC 协议不匹配，请同时更新应用与内核', raw.method);
  }
  if (!Array.isArray(raw.params)) throw new RpcError(RpcErrorCode.INVALID_PARAMS, 'params 必须是数组', raw.method);
  return createRpcRequest(raw.method, raw.params, endpoint);
}

export function rpcSuccess(method: number, result: RpcValue): RpcResult {
  const response: RpcResult = { protocolVersion: RPC_PROTOCOL_VERSION, method: method, result: result };
  decodeRpcResponse(JSON.stringify(response), method);
  return response;
}

export function rpcFailure(error: Error, method: number = -1): RpcResult {
  const fault = error instanceof RpcError ? error : new RpcError(RpcErrorCode.INTERNAL_ERROR, error.message || 'RPC 操作失败', method);
  return { protocolVersion: RPC_PROTOCOL_VERSION, method: fault.method, error: fault.message, errorCode: fault.code };
}

export function decodeRpcResponse(text: string, method: number): RpcResult {
  let response: RpcResult;
  try { response = JSON.parse(text) as RpcResult; } catch (_) {
    throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '响应不是有效 JSON', method);
  }
  if (!response || typeof response !== 'object' || Array.isArray(response)) {
    throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '响应必须是对象', method);
  }
  if (response.protocolVersion !== RPC_PROTOCOL_VERSION) {
    throw new RpcError(RpcErrorCode.INCOMPATIBLE_VERSION, 'RPC 协议不匹配，请同时更新应用与内核', method);
  }
  if (response.method !== method) throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '响应方法不匹配', method);
  if (response.error !== undefined || response.errorCode !== undefined) {
    if (typeof response.error !== 'string' || response.error === '' ||
      !Object.values(RpcErrorCode).includes(response.errorCode as RpcErrorCode) || response.result !== undefined) {
      throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '错误响应不符合协议', method);
    }
    throw new RpcError(response.errorCode as RpcErrorCode, response.error, method);
  }
  const spec = rpcMethod(method);
  if (response.streamReady !== undefined && response.streamReady !== true) {
    throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '订阅确认格式错误', method);
  }
  const valid = response.streamReady === true ? spec.stream && response.result === '' : matches(response.result, spec.result);
  if (!spec.supported || !valid) throw new RpcError(RpcErrorCode.INVALID_RESPONSE, `${spec.arkName}: 返回值不符合协议`, method);
  return response;
}

export function assertRpcCompatibility(content: string): RpcCapabilities {
  const shape = rpcMethod(ClashRpcType.GetCapabilities).result;
  if (!matches(content, shape)) throw new RpcError(RpcErrorCode.INCOMPATIBLE_VERSION, '内核兼容性信息缺失或格式错误');
  const info = JSON.parse(content) as RpcCapabilities;
  if (info.protocolVersion !== RPC_PROTOCOL_VERSION || info.nativeAbiVersion !== NATIVE_ABI_VERSION ||
    info.contractHash !== RPC_CONTRACT_HASH || !RPC_CAPABILITIES.every((capability) => info.capabilities.includes(capability))) {
    throw new RpcError(RpcErrorCode.INCOMPATIBLE_VERSION, '应用与内核接口不兼容，请安装同一次构建的完整应用包');
  }
  return info;
}
