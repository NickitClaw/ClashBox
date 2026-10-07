import { JSON, taskpool, util } from '@kit.ArkTS';
import { YamlUtils } from '../utils/YamlUtils';
import { YamlUtil } from '../utils/YamlUtil';

export interface ProfileTransformOptions {
  name: string;
  customRules: string[];
  deleteRules: string[];
  script: string;
  fixTlsFingerprint: boolean;
  yamlOverride: string;
}

/** No filesystem or RPC dependencies: importing and rewriting share the same transformation. */
export class ProfileTransformer {
  static decode(raw: string | ArrayBuffer): string {
    return typeof raw === 'string' ? raw :
      util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(raw));
  }

  static async prepare(raw: string | ArrayBuffer, options: ProfileTransformOptions): Promise<string> {
    // Copy observed arrays before passing primitive values to TaskPool.
    const rules: string[] = [];
    const deleted: string[] = [];
    options.customRules.forEach((r) => { rules.push(r); });
    options.deleteRules.forEach((r) => { deleted.push(r); });
    const task = new taskpool.Task(transformProfile, ProfileTransformer.decode(raw),
      JSON.stringify(rules), JSON.stringify(deleted), options.script, options.name,
      options.fixTlsFingerprint, options.yamlOverride);
    return await taskpool.execute(task) as string;
  }

  static needsRuleRepair(content: string, customRules: string[], deleteRules: string[]): boolean {
    const doc = YamlUtils.parseYamlSafe(content);
    const rules = (doc['rules'] ?? []) as string[];
    const normalize = (r: string): string => r.replace(/\s+/g, '');
    const actual = rules.map(normalize);
    const contains = (rule: string, deleting: boolean): boolean => {
      const normalized = normalize(rule);
      if (!normalized.endsWith(',MATCH')) return actual.includes(normalized);
      const prefix = normalized.substring(0, normalized.length - 5);
      return actual.some((r) => r.startsWith(prefix) && (deleting || r !== normalized));
    };
    return customRules.some((r) => !contains(r, false)) || deleteRules.some((r) => contains(r, true));
  }

  static providersLazy(content: string): string {
    return YamlUtils.injectProvidersLazy(content);
  }
}

@Concurrent
function transformProfile(content: string, rulesJson: string, deletedJson: string,
  script: string, name: string, fixTlsFingerprint: boolean, yamlOverride: string): string {
  if (!content.trim()) throw new Error('配置内容为空');
  let yamlContent = YamlUtils.convertUniversalToClashYaml(content) ?? content;
  const doc = YamlUtils.parseYamlSafe(yamlContent);
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    throw new Error('配置必须是 Clash YAML 对象或支持的节点链接');
  }
  if (yamlOverride.trim()) yamlContent = YamlUtils.applyYamlOverride(yamlContent, yamlOverride);
  return YamlUtil.executeScriptAndInject(yamlContent, script, name,
    JSON.parse(rulesJson) as string[], JSON.parse(deletedJson) as string[], fixTlsFingerprint);
}
