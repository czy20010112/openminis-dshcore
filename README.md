# openminis-dshcore

**OpenMinis 的 agent 内核换成 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）的 agent 框架**，保留原 app 的交互、工具实现与 UI。

原版 OpenMinis 的 agent loop 是一个单文件的大循环：请求拼装、工具调度、重试、压缩、持久化全挤在一起。这个 fork 把**决策内核**换成 DSH 的分层实现（agent / agent-loop / system-prompt / tools / llm / compaction / session 七个包移植进来），**工具本身一行没改**——每个工具仍然调用 OpenMinis 原本的实现。

## 两条线，一套流水线

| | iOS 15 线 | iOS 26 线 |
|---|---|---|
| 分支 | `main` | `ios26` |
| 基线 | [zhaoxiufei/OpenMinis](https://github.com/zhaoxiufei/OpenMinis)（部署目标 15.0） | [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis) v1.14（部署目标 16.0） |
| runner | `macos-14` / Xcode 16 | `macos-26` / Xcode 26 |
| 扩展 | 剔除 AgentWidget / MinisShare | 全量保留并逐个签名 |

`src/ios/DSH/` 那 21 个文件**两条线字节一致**，只有两个文件按分支不同（`DSHTurnDriver.swift` 适配 `.responseModel` 枚举、`DSHTurnDriverBridge.swift` 适配工具块的元组 arity 与行专属 block kind）。所以**内核改一次，两条线同时生效**。

## 下载

每次构建产出自己的 release（tag = 构建号）：

```bash
gh release list --repo czy20010112/openminis-dshcore --limit 5
gh release download <tag> --repo czy20010112/openminis-dshcore
```

| 产物 | 运行环境 |
|---|---|
| `MinisDSH-ios15-unsigned.ipa` | iOS 15.0+ arm64 |
| `MinisDSH-ios26-unsigned.ipa` | iOS 16.2+ arm64（内嵌 Agent Activity 扩展要求 16.2） |

两个都是**未签名**包，装在越狱设备（AppSync Unified）或用 TrollStore / Sideloadly。

**身份**：bundle id `com.openminis.minidsh`、App Group `group.com.openminis.minidsh` —— 故意与官方 OpenMinis 区分，两者可并存、互不干扰。**请直接装这个包，不要自己重签**：签名里带着 App Group entitlement，重签工具常把它丢掉，`containerURL` 返回 nil 会让 app 在启动瞬间崩。

## 架构文档

**[docs/DSH-ARCHITECTURE.md](docs/DSH-ARCHITECTURE.md)** —— 10 张图 + 逐项前后对照：原版长什么样、现在长什么样、**每一处差异的根因**。包括压缩如何跨重启持久化、六个循环入口如何全部改由 DSH 驱动、以及一条反复出现的缺陷模式（"原循环做的事，DSH 回合没做"）。

## 构建

推送到 `main` 或 `ios26` 即触发 `.github/workflows/build-ipa.yml`：两条线各自 checkout、编译、adhoc 签名（framework → appex → app，逐层带 entitlements）、打包，然后由一个 publish job 合并成一次 release。

手写一次测试构建（把压缩阈值降到 2000 token，便于在设备上触发压缩）：

```bash
gh workflow run build-ipa.yml \
  -f compaction_probe=true -f build_ios26=false -f create_release=false
```

探针构建产物名带 `-probe`，且 publish job 会拒绝发布它。

## 已知缺口

[docs/DSH-ARCHITECTURE.md §8](docs/DSH-ARCHITECTURE.md) 有完整的"已修 / 未修"两张表。最值得知道的一条：**group fallback 没有接进 DSH 回合**——主成员限流时直接失败报错，而不是静默换备（需要第二个 provider 才能实测，所以没动）。

## 上游与许可

本项目是 [OpenMinis](https://github.com/OpenMinis/OpenMinis) 的二次开发分支，遵循上游的 **GPL-3.0** 许可（见 [LICENSE](LICENSE)）。上游的 README 原文已不再适用，其内容与版权归原作者所有；本仓库只改动 agent 内核与构建流水线，未改动任何工具实现。
