# ClashBox

#### 介绍

ClashBox是一个HarmonyOS NEXT(OpenHarmony)平台的代理软件，使用改版的ClashMate内核

本分支的核心源码与原生构建方式见下方开发说明。

#### 食用方法

需要使用Auto-installer(https://github.com/likuai2010/auto-installer/)进行安装

#### 本分支开发与验证（HarmonyOS 7 / API 26）

本分支包含 Go/NAPI 包装层，并固定公开的兼容核心与 gVisor 源码。首次拉取后执行：

```sh
git submodule sync --recursive
git submodule update --init --recursive
```

原来的 `core` gitlink 指向同名 Python 项目，无法构建 Go 内核；现固定为
`xfz347/Clash.Meta` 的 `2ee8e1034c2a9407396eba04ba1a09619d1e2175`，gVisor 固定为核心要求的
`79317d808312e241b8da115b7e07a912c2e4631f`。这会替换原先未附匹配源码的预编译内核，升级后的协议与联网行为应在目标设备回归。

原生编译使用 [OpenHarmony-SIG Go](https://gitcode.com/openharmony-sig/ohos_golang_go)，已验证工具链提交
`302a5306b6fad2f47196360b82561d1db1f954cf`（`release-branch.go1.24`，Go 1.24.5），并用官方 Go 1.24.0 引导编译：

```sh
# 在工具链仓库的 src 目录执行，GOROOT_BOOTSTRAP 指向官方 Go 安装目录
GOROOT_BOOTSTRAP=/path/to/bootstrap-go GOTOOLCHAIN=local ./make.bash

# 回到 ClashBox 根目录
OHOS_GO=/path/to/ohos_golang_go/bin/go \
OHOS_NATIVE_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native \
bash proxy_core/src/flclash/build.sh arm64

devecocli build --modules entry --build-mode debug
```

默认构建未签名 HAP，不依赖原作者的证书路径。真机安装需在自己的 DevEco Studio 中配置签名。当前提供 arm64 内核；amd64 需要单独编译并补齐其它原生依赖。

`appPath`、`CommonVpnService` 和 `FlClashVpnService` 的唯一源码入口为 `.ets`。
构建缓存和 source map 的模块键可能以 `.ts` 结尾，其 `sources` 字段仍指向 `.ets`；不要将生成文件复制回源码目录，也不要维护同路径同名的 `.ts` / `.ets` 两套实现。

配置开发入口为 `proxy_core/src/main/ets/Profile.ets`，具体职责分配如下：

| 模块 | 职责 |
| --- | --- |
| `profile/ProfileDownloader.ets` | 原生/系统 HTTP 下载、响应元数据与下载临时文件清理 |
| `profile/ProfileTransformer.ets` | 节点链接转换、YAML 覆写、脚本与规则处理；通过 TaskPool 执行 |
| `profile/ProfileStorage.ets` | 按配置的跨进程锁、完整读写、内核校验、原子替换与脚本备份 |

新增配置修改功能应调用 `Profile`，不要在页面或后台任务直接覆盖 `config.yaml`：

- `save` / `saveByUri` / `update` 共用转换与存储流程，订阅元数据在配置提交成功后更新。
- `saveByUri(uri, validate, ...)`、`repairMissingRules(validate, ...)`、`forceRewriteRules(validate, ...)` 和 `ensureProvidersLazy(validate)` 必须提供内核校验回调，例如 `(path: string): Promise<string> => socketProxy.vailConfig(path)`；空字符串表示通过，其它结果或异常使操作失败。
- 手动编辑调用 `ClashViewModel.saveProfileContent(id, content, expectedContent)`，保留编辑后的 YAML 文本和注释；不重复执行脚本/覆写。保存时在锁内比较打开编辑器时的内容，拒绝覆盖后台更新或已删除的配置。
- 规则修复、重排、provider 迁移和脚本操作在同一把锁内完成读取、转换、校验和替换。`false` 表示未修改或目标不存在，实际失败通过异常向上传递。
- 脚本重应用从首次备份开始，避免重复叠加修改；恢复失败保留备份。导入新配置或手动保存成功后清除旧脚本备份。

`ProfileStorage.transaction` 回调中的 `ProfileTransaction` 只在当前事务内有效，不能嵌套获取同一配置的锁。
内核校验和最终替换使用同一个唯一临时文件，校验失败、取消或写入失败时不会先截断现有配置。

配置切换统一调用 `ClashViewModel.activateProfile(id, update)`，配置页和收藏入口不再直接改写当前选择。
`ConfigActivationService` 串行执行更新、读取快照、内核加载和选择提交；过期操作不能发布选择，普通重载在队列中读取最新选择。
加载失败或加载过程中被新请求取代时，用上一次确认的 YAML 与设置快照恢复；恢复失败会尝试停止 VPN 并报告错误。
内核解析失败保留原运行配置，缺失/损坏文件不会再回退并应用默认配置。
大 YAML 经独立临时文件传给内核，请求完成后清理，不占用 RPC 帧空间；设置 patch 保留已生效的节点/规则快照。
后台订阅更新只更新磁盘内容，切换或完整重载后才会生效。

IPC 请求和响应统一使用「4 字节大端 UTF-8 字节数 + JSON」帧，单帧上限 4 MiB；日志连接支持连续多帧。
因此 ArkTS 客户端、扩展进程和 `libflclash.so` 必须一起更新。NAPI `startTun` 返回 `Promise<boolean>`，
`stopTun` 返回 `Promise<void>`，完成/失败均由原生层确认。不要替换回旧 `.so` 后仅测试前端构建。

RPC 定义集中在 `protocol/rpc.schema.json`：方法编号、端点、参数和返回值类型、错误码与兼容性版本都从这里维护。
修改后执行 `node scripts/generate-rpc.cjs`，提交清单和生成的 ArkTS/Go 文件；
`node scripts/generate-rpc.cjs --check` 可检查生成文件是否过期，原生构建和回归测试会执行此检查。
保留已有编号（0–33），新增方法使用新编号；移除的方法保留编号并设置 `supported: false`，禁止复用。
`registerOnMessage` 尚未实现，调用会明确返回 `UNSUPPORTED_METHOD`。
`queryTunnelState`（1）由 VPN 端点返回状态快照：阶段、确认的运行标志、运行意图、启动时间、意图序号和错误。
阶段为 `stopped / starting / running / stopping / recovering / failed / unknown`，扩展进程的串行操作队列维护此状态。
UI 前台每两秒同步一次；失败查询保留上次确认的运行标志，同时显示 `unknown`，不发送“已停止”事件。
页面与卡片消费状态投影，扩展进程在后台直接更新卡片并管理常驻通知；停止/状态查询不依赖 Go 握手成功。

请求包含 `protocolVersion`、`method` 和 `params` 数组；成功响应包含同版本、同方法和 `result`，
失败响应包含 `errorCode`、`error` 且不包含 `result`。保留现有业务数据的 JSON 字符串编码，
两端都会检查嵌套 JSON 的必要字段；配置内容本身仍由内核校验。日志订阅先返回 `streamReady: true`，随后发送日志帧。
新增方法除修改清单外，还需实现对应处理逻辑，并向 `tests/fixtures/rpc-wire.json` 添加独立的有效/无效样例。

启动前检查 NAPI `getCompatibilityInfo()`，普通 RPC 和订阅前通过 `GetCapabilities`（34）确认远端兼容性。
检查协议版本、原生接口版本、清单摘要和必需能力；任意不一致都会拒绝启动并提示安装同次构建的完整包。
连接故障或内核切换后重新握手。修改帧格式/响应封装时递增 `protocolVersion`；
修改 NAPI 签名或完成语义时递增 `nativeAbiVersion`。清单变化会自动更新摘要，需同步重建并提交 `.so`。

回归测试执行实际仓库代码，使用受控的系统 API 替身覆盖异步竞态。轻量检查只需 Node.js 与官方 Go，无需 DevEco/设备：

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run check
# go 未加入 PATH 时：GO_BIN=/path/to/go npm run check
# 单独执行 ArkTS 逻辑回归：npm test
# 使用 DevEco 转译器核对时：CLASHBOX_TYPESCRIPT=/path/to/typescript.js npm test

# Go 帧协议和契约测试，无第三方依赖；支持官方 Go（从仓库根目录执行）
GO111MODULE=off go test -race -v ./proxy_core/src/flclash/rpcframe ./proxy_core/src/flclash/rpccontract
```

`.github/workflows/checks.yml` 在 main 推送和 PR 上执行同一套检查。测试工具版本由 `package-lock.json` 固定，
GitHub Actions 按提交 SHA 固定。轻量 CI 检查生成文件、原生源码/二进制摘要、回归测试和 Go 竞态测试。
编译器语义检查仍以完整 ArkTS 构建为准，Node 转译测试不能替代它。

在已安装 API 26、OpenHarmony Go 和 `devecocli` 的开发机上，初始化子模块并执行 `ohpm install --all` 后：

```sh
# 将 DevEco Node/Java/ohpm/devecocli 加入当前 shell 的 PATH；可指定 OHOS_GO、OHOS_NATIVE_HOME、GO_BIN。
bash scripts/build-hap.sh
```

脚本重新编译 arm64 内核、运行检查、清理并构建未签名 HAP，最后核对打包库的 ELF 可加载内容。
`proxy_core/libs/arm64-v8a/libflclash.build.json` 随库提交，记录原生源码摘要、子模块版本、编译器、SDK 和库摘要；
修改原生源码/协议后若未重建，CI 会失败。HAP 旁的 `entry-default-unsigned.build.json` 额外记录应用提交、工作区状态和包摘要。
完整 HAP 构建在开发机执行；GitHub 托管任务不安装 DevEco SDK，也不配置签名或发布安装包。

#### 模拟器内核调试

部分模拟器镜像缺少 `com.huawei.hmos.vpndialog`，无法完成系统 VPN 授权。
Debug 构建可通过冷启动参数运行 UI 进程内的真实 Go 内核和双端 IPC，验证配置导入、校验、
数据库保存、配置激活、代理组查询和错误处理：

```sh
hdc -t 127.0.0.1:5555 install -r entry/build/default/outputs/default/entry-default-unsigned.hap
hdc -t 127.0.0.1:5555 shell aa force-stop org.xbgroup.clashboxLTS
hdc -t 127.0.0.1:5555 shell aa start -a EntryAbility -b org.xbgroup.clashboxLTS --pb clashbox.debugCoreOnly true
```

该选项仅在 Debug 构建的 `onCreate` 生效，不写入首选项；Release 构建忽略此参数。
调试模式下，界面和 IPC 均明确拒绝启动系统 VPN，状态保持未连接，不创建 TUN，也不启动代理监听端口。
不要将配置导入和代理组查询通过视为 VPN 流量转发通过。退出该模式需强制停止后不带此参数重新启动。
日志中的“内核调试模式已就绪”表示 NAPI 与 Go IPC 兼容性检查均已完成。

日常 VPN 使用普通 mihomo，由 VPN 扩展进程运行核心。“设置 → 内核”只提供该模式。
Debug 构建额外提供“设置 → 开发者选项 → 前台模式 (mihomo)”，用于在 UI 进程中调试实际 VPN；
切换应用或锁屏后该进程可能被冻结，不能将此模式用于持续后台代理。切换模式会等待 VPN 停止，再退出应用，需手动重新打开。
Release 不提供开发者入口，并在配置加载、备份恢复、卡片配置及核心启动时将旧的前台模式选择归一为普通 mihomo。
这与上面的 `clashbox.debugCoreOnly` 不同：后者用于无法建立 TUN 的模拟器，不启动系统 VPN。

基础初始化（Context、首选项和数据库）先于内核启动；VPN 授权失败不会中断其初始化。
持久化状态在 UIContent 就绪后、页面组件创建前恢复，初始化结束主动刷新配置列表。
系统 VPN 授权等待有超时提示，授权完成后可重试。自动更新任务的注册/取消串行执行，
取消时使用系统已登记任务的完整条件，无任务时直接返回。

首次安装直接进入主页，不自动展示用户协议、欢迎向导或更新日志，并记录当前版本，避免第二次启动补弹日志。
协议、隐私政策和更新日志仍可在设置中手动查看；已有用户升级时保留更新日志及数据迁移，崩溃提示和链接导入不受影响。

配置页的刷新按钮与下拉刷新统一等待订阅更新完成，再重新加载本次更新涉及的当前配置；刷新期间切换配置不会被旧操作切回。
批量测速对节点去重，每批最多 20 个，通过一个 IPC 请求测试，重复点击合并。节点超时或不可用仅在页面显示结果，不弹出汇总提示；
服务连接中断时终止后续批次，清理待测状态并只提示一次，不将服务错误逐节点弹出。

设备验证还应覆盖：后台锁屏后代理流量、通知开关、连续启停、扩展进程被回收后重连，以及自动更新与手动编辑同时发生。

本次界面修复的签名真机包还需验证：

- 冷启动已有配置后立即点右上角刷新、下拉刷新、快速重复点击：无占位配置错误，更新完成后代理组与订阅内容一致。
- 空配置列表、选中配置已删除、刷新其他订阅、刷新期间切换配置：无误加载或切回；下载失败只报告失败并停止刷新动画。
- 大节点组、部分节点超时、连续点击测速、测速期间停止核心：节点退出加载状态，结果正确排序，错误不逐条弹出。
- 全新安装及第二次打开均不弹协议或日志；设置中的手动入口可用，升级迁移、崩溃提示和链接导入仍可用。
