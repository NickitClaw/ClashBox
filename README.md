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

IPC 请求和响应统一使用「4 字节大端 UTF-8 字节数 + JSON」帧，单帧上限 4 MiB；日志连接支持连续多帧。
因此 ArkTS 客户端、扩展进程和 `libflclash.so` 必须一起更新。NAPI `startTun` 返回 `Promise<boolean>`，
`stopTun` 返回 `Promise<void>`，完成/失败均由原生层确认。不要替换回旧 `.so` 后仅测试前端构建。

回归测试执行实际仓库代码，使用受控的系统 API 替身覆盖异步竞态：

```sh
# ohpm 依赖与 DevEco Studio 已安装；非默认安装位置可设 CLASHBOX_TYPESCRIPT
node --test tests/regression.cjs

# Go 帧协议测试，无第三方依赖；支持官方 Go
cd proxy_core/src/flclash/rpcframe
GO111MODULE=off go test -race -v
```

设备验证还应覆盖：后台锁屏后代理流量、通知开关、连续启停、扩展进程被回收后重连，以及自动更新与手动编辑同时发生。
