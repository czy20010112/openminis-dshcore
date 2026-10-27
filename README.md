# openminis-dshcore

**OpenMinis 的 agent 内核换成 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）的 agent 框架**，保留原 app 的交互、工具实现与 UI。

> **这是 OpenMinis 的修改版**（GPL-3.0 §5(a)）。最近一次修改：**2026-10-27**。
> 上游项目：[OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis)（GPL-3.0）。
> 本仓库与 OpenMinis 官方无关，不代表其立场；名字与图标等品牌元素不随 GPL 授权，本仓库沿用上游名称仅为说明来源。

原版 OpenMinis 的 agent loop 是一个单文件的大循环：请求拼装、工具调度、重试、压缩、持久化全挤在一起。这个 fork 把**决策内核**换成 DSH 的分层实现（agent / agent-loop / system-prompt / tools / llm / compaction / session 七个包移植进来），**工具本身一行没改**——每个工具仍然调用 OpenMinis 原本的实现。

## 两条线，一套流水线

| | iOS 15 线 | iOS 26 线 |
|---|---|---|
| 分支 | `main` | `ios26` |
| 基线 | [zhaoxiufei/OpenMinis](https://github.com/zhaoxiufei/OpenMinis)（部署目标 15.0） | [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis) v1.14（部署目标 16.0） |
| runner | `macos-14` / Xcode 16 | `macos-26` / Xcode 26 |
| 扩展 | 剔除 AgentWidget / MinisShare | 全量保留并逐个签名 |

`src/ios/DSH/` 那 65 个文件**两条线字节一致**，只有两个文件按分支不同（`DSHTurnDriver.swift` 适配 `.responseModel` 枚举、`DSHTurnDriverBridge.swift` 适配工具块的元组 arity 与行专属 block kind）。所以**内核改一次，两条线同时生效**。

## 这一版新增：把「手机上远程用另一台电脑上的 DSH」做成和本机对话一样

**读远端会话**

- 模型切换提示、注入的上下文、运行时记录按 `source.kind` 分流：用户的仍显示成气泡，系统的不再冒出一句「人话」。
- 思考块回到它该在的位置：每个 `ContentPart.reasoning` 就地成为 thinking 块，`thinking → tool → thinking → text` 按真实顺序交错，而不是全塌到顶部。
- 行在列表布局前先自测高度。iOS 15 的自适应高度对某些 hosted cell 会抛异常并退回粗估，远端页面现在填同一套 TextKit 元数据，让退回值精确——文字不再压住下一行。
- 宽屏（iPad / 横屏）内容列封顶 900pt 并与本机一致，不再从左铺到右。

**在远端会话里生活**

- 输入框的发送、停止、排队与本地一致。
- `/` 唤起与本机相同的命令表，每行标注 `→ PC`（交给配对的电脑执行，作为普通文本发送）或 `Local`（只影响本机，并且会说明原因，绝不把宿主看不懂的命令发出去）。
- 上下文圆环可点开，显示宿主**自己的**测量值（已用 / 窗口 / 剩余 / 占比，以及最近一次压缩），与本机弹窗共用同一个视图、同一套行；宿主没上报的行写「这台电脑没上报」，不画 0%。
- goal / todo 面板出现在输入框上方，几何与本机一致，数据来自宿主投影。
- 看门狗盯住死掉的连接：15 秒没有心跳挂出细横幅，30 秒关闭并重连。心跳算存活，空闲会话的 `-1` cursor 不再被丢弃（否则一个健康的空闲会话必然被误判为死连接）。

**把活派给那台电脑**

- `remote_team_spawn` / `_message` / `_list` / `_output` / `_interrupt` 驱动宿主真正的 Agent Team：有名字、可继续对话、可打断的队友，而不是一次性的 subagent。
- `remote_team_output` 负责取回结论，模型不再用 shell 轮询或反复问「好了吗」。
- 派发策略写进系统提示词：需要完整桌面环境、用户点名那台机器、需要那台机器才有的数据、预计超过几分钟的任务交给电脑；闲聊与小脚本留在手机。

**打开更快**

- 远端转写本地留一份镜像（`dsh-cache/<sessionId>.json`，只存 records，不缓存 goal/todos/summary），打开时先立刻上屏，再向宿主要 cursor 之后的部分。
- 宿主在帧上说明自己做了什么：`resumed`（续传，按条追加）或 `reset`（整页，替换缓存）。缺字段按 `reset` 处理——错的追加比多要一页糟糕得多。

## 下载

每次构建产出自己的 release（tag = 构建号）：

```bash
gh release list --repo czy20010112/openminis-dshcore --limit 5
gh release download <tag> --repo czy20010112/openminis-dshcore
```

| 产物 | 内容 |
|---|---|
| `MinisDSH-ios15-build143.ipa` | iOS 15.0+ arm64，ad-hoc 签名（逐层：framework → appex → app） |
| `MinisDSH-ios26-build143.ipa` | iOS 16.2+ arm64（内嵌 Agent Activity 扩展要求 16.2），ad-hoc 签名 |
| `MinisDSH-ios*-unsigned.ipa` | CI 产出的未签名包，供自行签名 |

装在越狱设备（AppSync Unified）或用 TrollStore / Sideloadly。**请直接装这个包，不要自己重签**：签名里带着 App Group entitlement，重签工具常把它丢掉，`containerURL` 返回 nil 会让 app 在启动瞬间崩。

**身份**：bundle id `com.openminis.minidsh`、App Group `group.com.openminis.minidsh` —— 故意与官方 OpenMinis 区分，两者可并存、互不干扰。

## 隐私

- **没有遥测**，不向任何第三方上报使用数据。
- 配对是一台手机 ↔ 一台电脑：凭据存在 Keychain（access / refresh 令牌，refresh 会轮换），配对可以随时在设置里解除，解除即删除令牌与本地转写镜像。
- provider 的 API Key 走 Keychain，不进 `UserDefaults`、不进 iCloud 备份。
- 设备日志不打印配对的 host 地址与 server id（仅 `DEBUG` 构建打印）。
- 远端转写镜像只存在本机 Application Support，并排除 iCloud 备份。

## 架构文档

**[docs/DSH-ARCHITECTURE.md](docs/DSH-ARCHITECTURE.md)** —— 10 张图 + 逐项前后对照：原版长什么样、现在长什么样、**每一处差异的根因**。包括压缩如何跨重启持久化、六个循环入口如何全部改由 DSH 驱动、以及一条反复出现的缺陷模式（"原循环做的事，DSH 回合没做"）。

## 构建

推送到 `main` 或 `ios26` 即触发 `.github/workflows/build-ipa.yml`：两条线各自 checkout、编译、adhoc 签名、打包，然后由一个 publish job 合并成一次 release。

手写一次测试构建（把压缩阈值降到 2000 token，便于在设备上触发压缩）：

```bash
gh workflow run build-ipa.yml \
  -f compaction_probe=true -f build_ios26=false -f create_release=false
```

探针构建产物名带 `-probe`，且 publish job 会拒绝发布它。

## 已知缺口

[docs/DSH-ARCHITECTURE.md §8](docs/DSH-ARCHITECTURE.md) 有完整的"已修 / 未修"两张表。最值得知道的一条：**group fallback 没有接进 DSH 回合**——主成员限流时直接失败报错，而不是静默换备（需要第二个 provider 才能实测，所以没动）。

## 上游与许可

本项目是 [OpenMinis](https://github.com/OpenMinis/OpenMinis) 的二次开发分支，遵循上游的 **GPL-3.0** 许可（见 [LICENSE](LICENSE)）。

按 GPL-3.0 的要求：源码随二进制一并提供（本仓库即对应源码）、保留原作者版权声明、并在此显著声明本仓库为修改版与其修改日期（见页首）。GPL-3.0 **不授予商标权**：上游的项目名与图标仍归其作者所有，不随代码许可授权；若要在发布物中去掉或更换品牌元素，那属于 GPL 允许的修改，但**不能反过来声称是官方版本**。

上游 README 的原文已不再适用，其内容与版权归原作者所有；本仓库只改动 agent 内核、远端会话能力与构建流水线，未改动任何工具实现。
