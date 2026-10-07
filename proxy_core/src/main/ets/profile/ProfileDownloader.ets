import fs from '@ohos.file.fs';
import { Context } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { JSON, util } from '@kit.ArkTS';
import { SocketProxyService } from '../rpc/SocketProxyService';
import { generateUUID, readProfileText, writeProfileText } from './ProfileStorage';

export interface DownloadedProfile {
  content: string;
  name: string | null;
  userinfo?: string;
}

/** Owns only network IO and its temporary files. Validation/commit belong to ProfileStorage. */
export class ProfileDownloader {
  private context: Context;
  private socket: SocketProxyService;
  private cancelled?: () => boolean;

  constructor(context: Context, socket: SocketProxyService, cancelled?: () => boolean) {
    this.context = context;
    this.socket = socket;
    this.cancelled = cancelled;
  }

  private checkCancelled(): void {
    if (this.cancelled?.()) throw new Error('配置操作已取消');
  }

  async download(url: string, ua: string): Promise<DownloadedProfile> {
    const temp = `${this.context.tempDir}/subscription-${generateUUID()}.yaml`;
    let nativeFailed = false;
    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        this.checkCancelled();
        try {
          let result: string;
          if (!nativeFailed) {
            try {
              result = await this.socket.downloadConfig(url, ua, temp);
            } catch (_) {
              this.checkCancelled();
              nativeFailed = true;
              result = await this.downloadConfigFallback(url, ua, temp);
            }
          } else {
            result = await this.downloadConfigFallback(url, ua, temp);
          }
          this.checkCancelled();
          const metadata = JSON.parse(result) as Record<string, string>;
          const content = await readProfileText(temp);
          if (!content.trim()) throw new Error('订阅返回内容为空');
          return { content: content, name: getFileNameFromDisposition(metadata['content-disposition']),
            userinfo: metadata['subscription-userinfo'] };
        } catch (e) {
          this.checkCancelled();
          if (attempt === 1) throw e as Error;
          try { await fs.unlink(temp); } catch (_) {}
          await new Promise<void>((resolve) => { setTimeout(resolve, 1000); });
        }
      }
      throw new Error('下载配置失败');
    } finally {
      try { await fs.unlink(temp); } catch (_) {}
    }
  }

  private async downloadConfigFallback(url: string, ua: string, filePath: string): Promise<string> {
    const httpRequest = http.createHttp()
    // 确保内置的 Let's Encrypt YE1 中间证书可用（rawfile → 应用目录）：
    // 部分订阅源服务器只发送叶子证书、缺失中间证书，导致链验证失败；
    // 用 caPath 补全中间证书即可通过系统 http 模块的证书校验
    let caFile = ''
    try {
      const baseDir = this.context?.filesDir ?? this.context?.tempDir ?? ''
      const target = baseDir + '/int-ye1.pem'
      if (baseDir !== '' && !await fs.access(target)) {
        const raw = await this.context?.resourceManager.getRawFileContent('int-ye1.pem')
        if (raw && raw.length > 0) {
          const tempCa = `${target}.${generateUUID()}.tmp`;
          try {
            const cert = util.TextDecoder.create('utf-8').decodeToString(raw);
            await writeProfileText(tempCa, cert);
            await fs.rename(tempCa, target);
          } finally {
            try { await fs.unlink(tempCa); } catch (_) {}
          }
        }
      }
      if (await fs.access(target)) caFile = target
    } catch (e) {
      console.warn(`[Profile] 准备 CA 证书失败: ${(e as Error).message}`)
    }
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 20000,
        readTimeout: 30000,
        header: { 'User-Agent': ua }
      }
      if (caFile !== '') {
        options.caPath = caFile
      }
      const resp = await httpRequest.request(url, options)
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`)
      }
      // 响应可能是 string 或 ArrayBuffer，统一转为字符串落盘
      let content: string
      if (typeof resp.result === 'string') {
        content = resp.result
      } else if (resp.result instanceof ArrayBuffer) {
        const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
        content = decoder.decodeToString(new Uint8Array(resp.result))
      } else {
        throw new Error('响应内容格式异常')
      }
      await writeProfileText(filePath, content)
      // 提取响应头（原生 downloadConfig 返回 JSON，含 content-disposition / subscription-userinfo）
      const headers = (resp.header ?? {}) as Record<string, string | string[]>
      const first = (v: string | string[] | undefined): string => {
        if (v === undefined) return ''
        return Array.isArray(v) ? (v[0] ?? '') : v
      }
      // HTTP 头键名大小写不敏感：系统 http 模块返回的 header 键可能是
      // "Content-Disposition" 或 "content-disposition"，统一小写比较避免取不到
      const getHeader = (name: string): string => {
        const lower = name.toLowerCase()
        const keys = Object.keys(headers)
        for (let i = 0; i < keys.length; i++) {
          if (keys[i].toLowerCase() === lower) {
            return first(headers[keys[i]])
          }
        }
        return ''
      }
      const configInfo: Record<string, string> = {}
      const disposition = getHeader('content-disposition')
      const userinfo = getHeader('subscription-userinfo')
      if (disposition) configInfo['content-disposition'] = disposition
      if (userinfo) configInfo['subscription-userinfo'] = userinfo
      return JSON.stringify(configInfo)
    } finally {
      httpRequest.destroy()
    }
  }

  static defaultName(url: string): string | null {
    if (!url) return null
    try {
      // 剥离查询参数
      const noQuery = url.split('?')[0] ?? url
      // 取路径最后一段非空片段
      const segments = noQuery.split('/')
      for (let i = segments.length - 1; i >= 0; i--) {
        const seg = segments[i].trim()
        if (seg && seg !== '' && !seg.startsWith('http')) {
          // 截断过长片段，避免把整段 token 当名字
          return seg.length > 40 ? seg.substring(0, 40) : seg
        }
      }
      // 无路径片段时用主机名
      const hostMatch = url.match(/^https?:\/\/([^\/:]+)/)
      return hostMatch ? hostMatch[1] : null
    } catch (e) {
      return null
    }
  }

}

function getFileNameFromDisposition(disposition: string | null | undefined): string | null {
  if (!disposition) return null;
  // 去除字符串两端的空格
  const cleanDisposition = disposition.trim();
  // 优先尝试解析 RFC 5987 格式
  // 使用正则，允许大小写、空格等变化
  const filenameStarRegex = /filename\*\s*=\s*(?:UTF-8|utf-8)\s*''\s*([^;]+)/i;
  const filenameStarMatch = cleanDisposition.match(filenameStarRegex);
  if (filenameStarMatch && filenameStarMatch[1]) {
    // 去除可能的空格并进行 URL 解码（非法百分号编码会抛异常，容错返回原始值）
    const encodedFileName = filenameStarMatch[1].trim();
    try {
      return decodeURIComponent(encodedFileName);
    } catch (e) {
      return encodedFileName;
    }
  }
  // 无 filename*，尝试解析普通的 filename=
  const filenameRegex = /filename\s*=\s*"?([^;"]+)"?/i;
  const filenameMatch = cleanDisposition.match(filenameRegex);
  if (filenameMatch && filenameMatch[1]) {
    return filenameMatch[1].trim();
  }

  // 都没匹配到，返回 null
  return null;
}
