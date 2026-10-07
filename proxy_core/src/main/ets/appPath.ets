import { Context } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { Xb_GlobalContext } from 'xb_components';

const profilesDirectoryName = "/profiles";


export async function getHome(context: Context | undefined): Promise<string>{
  let home = context?.filesDir + "/ClashBox"
  if (!await fs.access(home, fs.AccessModeType.EXIST)){
    try { await fs.mkdir(home) } catch (e) { if (!await fs.access(home)) throw e as Error }
  }
  return home
}
export async function getProfilesPath(context: Context | undefined): Promise<string> {
  let dir = await getHome(context) + profilesDirectoryName
  if(!await fs.access(dir, fs.AccessModeType.EXIST)){
    try { await fs.mkdir(dir) } catch (e) { if (!await fs.access(dir)) throw e as Error }
  }
  return dir
}
export async function getProfilePath(context: Context | undefined, id: string) {
  return await getProfileDir(context, id) + `/config.yaml`
}
export async function getProfileDir(context: Context | undefined, id: string) {
  const directory = await getProfilesPath(context);
  // 兼容ClashMeta 核心的文件目录
  if(!await fs.access(directory + `/${id}`, fs.AccessModeType.EXIST)){
    try { await fs.mkdir(directory + `/${id}`) } catch (e) { if (!await fs.access(directory + `/${id}`)) throw e as Error }
  }
  return directory + `/${id}`
}