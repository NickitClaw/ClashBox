import {  VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { SocketStubService } from 'proxy_core';
import { cardManager } from '../common/utils/CardManageUtil';
import { ClashCore } from './AppState';
import fs from  "@ohos.file.fs"
import { writeFile } from 'proxy_core/src/main/ets/fileUtils';
import util from '@ohos.util';


export default class ClashVpnAbility extends VpnExtensionAbility {

  clashStubService: SocketStubService | undefined
  constructor() {
    super();
  }
  async onCreate(want: Want) {
    try {
      let core = want.parameters?.["ClashCore"] as ClashCore ?? ClashCore.mihomo
      let requestId = want.parameters?.["requestId"] as number
      if(core == ClashCore.mihomo){
        console.log("ClashBox", `启用核心 mihomo`);
        cardManager.init(this.context);
        this.clashStubService = new SocketStubService(this.context, (state) => { cardManager.pushCartVpnState(state, true); })
        await this.clashStubService.startService(requestId)
        console.log("ClashBox", `启用核心 mihomo 成功`);
      }else{
        console.log("ClashBox", `前台模式`);
      }
    } catch (e) {
      console.log("ClashBox", `启用VPN失败 ${e.message} ${e.stack}`);
    }
  }
  async lockVpn(local: number){
    let lockPath = this.context.filesDir + '/vpn_ipc.lock';
    let encoder = new util.TextEncoder()
    writeFile(lockPath, encoder.encodeInto(local + ""))
  }
  async onDestroy(): Promise<void> {
    try {
      await this.clashStubService?.destroy()
    } catch (e) {
      console.warn('VPN 扩展清理失败', (e as Error).message)
    }
  }

};



