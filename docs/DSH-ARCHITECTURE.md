# OpenMinis × DSH agent 内核 — 架构与前后差别

本文回答三件事：**原来长什么样**、**现在长什么样**、**每一处差异的根因是什么**。

所有"原来"的引用都指向 `zhaoxiufei/OpenMinis` main（iOS 15 基线，本地 `upstream/main`）；
"现在"指向本文档所在仓库的 HEAD。

---

## 0. 一页对照

```mermaid
flowchart TB
    subgraph BEFORE["【原来】AIChatViewModel 一处承担全部"]
        direction TB
        B1["runAgentLoop()<br/>turn 主循环 + 压缩 + 重锚，全在一个函数族里"]
        B2["baseSystemPrompt<br/>字符串拼接，3 个调用点各拼一遍"]
        B3["makeAgentTools()<br/>199 行手写 AgentToolDefinition 字面量"]
        B4["withTaskGroup + maxConcurrentTools=10<br/>结果按 idx 字典缝合"]
        B5["AIChatViewModel+Compaction.swift<br/>1084 行 marker / anchor / sortOrder"]
        B6["agentHistory: [AgentMessage]<br/>可变裸数组，裸 Int 索引寻址"]
        B7["91 处 [T-*-ios] 补丁<br/>（AIChatViewModel.swift 一个文件占 18 处）"]
        B6 --> B7
        B1 --> B6
        B2 --> B1
        B3 --> B1
        B4 --> B1
        B5 --> B6
    end

    subgraph AFTER["【现在】决策内核外移，交互层原地不动"]
        direction TB
        A0["AIChatViewModel（保留）<br/>流式呈现 · 持久化 · 图片预算 · group fallback · TTS · 队列 · 取消清理 · UI"]
        A1["3 个调用点分支<br/>useDSHAgentLoop ? runDSHTurn() : runAgentLoop()"]
        A2["DSH agent 内核（新增 20 文件 / src/ios/DSH）"]
        A0 --> A1 --> A2
        A2 --> A3["装配 DSHSystemPrompt + DSHMinisPrompt<br/>有序 section 注册表 + 严格插值"]
        A2 --> A4["工具面 DSHToolRegistry + DSHMinisTools<br/>+ 两个 Bridge（schema / 并发）"]
        A2 --> A5["决策 DSHTurnDriver<br/>turn 循环 · 请求推导 · 落盘顺序"]
        A2 --> A6["调度 DSHToolScheduler + DSHToolGate<br/>声明式并发 · 派发前守卫"]
        A2 --> A7["状态 DSHSession + DSHSeq<br/>append-only 日志 + shadow 表面"]
        A2 --> A8["压缩 DSHCompaction<br/>selectCompactableRange 规则"]
    end

    B6 -. "同一类状态，两种身份模型" .-> A7
    B4 -. "同一件事，两种并发模型" .-> A6
    B5 -. "同一件事，两种压缩模型" .-> A8
```

**替换的五个"决策段"**：系统提示词装配、工具注册与 schema、工具调度、会话身份、压缩。
**保留的一切**：流式渲染、持久化、图片预算、group fallback、TTS、队列、取消清理、全部 UI，以及**每个工具的实际实现**（handler 原地复用）。

---

## 1. 分层结构

```mermaid
flowchart LR
    subgraph L1["SwiftUI / UIKit 层 — 未改"]
        V["AIChatView<br/>AssistantBlockView<br/>compactDividerRow"]
    end

    subgraph L2["AIChatViewModel — 90% 保留"]
        VM["ObservableObject<br/>streamingUIUpdatesSuspended / dshMaybeFlushText<br/>persistAgentMessage / imageBudgetActor<br/>QueuedPrompt / resumeQueueAfterCancel<br/>userDidCancel / handleUserCancelledCleanup"]
        VMx["+ DSH 扩展（extension）<br/>runDSHTurn · DSHTurnDriverDelegate<br/>dshAgentRegistry · dshRunShell 等 handler 实现"]
    end

    subgraph L3["DSH agent 内核 — 新增"]
        PROMPT["DSHSystemPrompt<br/>DSHMinisPrompt"]
        TOOLS["DSHToolRegistry<br/>DSHMinisTools<br/>DSHToolSchemaBridge<br/>DSHToolDispatchBridge"]
        DRIVER["DSHTurnDriver"]
        SCHED["DSHToolScheduler<br/>DSHToolGate"]
        SESS["DSHSession<br/>DSHSeq · DSHToolPairing"]
        COMP["DSHCompaction"]
        TYPES["DSHTypes<br/>provider 中立词表"]
    end

    subgraph L4["Minis 既有能力 — 复用"]
        P["AgentProvider（Anthropic / Gemini / OpenAI 兼容）"]
        H["executeSingleToolUse / shell / 文件 / memory 后端"]
        DB["ChatStore / RawMessage 持久化"]
    end

    V --> VM
    L2 --> L3
    DRIVER --> PROMPT
    DRIVER --> TOOLS
    DRIVER --> SESS
    DRIVER --> SCHED
    DRIVER --> COMP
    DRIVER --> P
    SCHED --> H
    PROMPT --> TYPES
    TYPES --> P
    VMx --> DB
```

关键边界：**DSH 内核不认识 `AIChatViewModel`，也不认识 `ChatMessage`。**
它只认识 `DSHMessage` / `DSHContentBlock` / `DSHToolExecutionResult`，进出都靠两个 Bridge 翻译。
这条边界就是"能同时移植到 iOS 15 与 iOS 26 两条源码线"的原因——内核与 Minis 的耦合只集中在 4 个 Bridge 文件里。

---

## 2. 一轮 turn 的时序

```mermaid
sequenceDiagram
    autonumber
    participant U as 用户
    participant VM as AIChatViewModel
    participant D as DSHTurnDriver
    participant S as DSHSession
    participant C as DSHCompaction
    participant P as AgentProvider
    participant SC as DSHToolScheduler
    participant G as DSHToolGate

    U->>VM: send()
    VM->>VM: 并发槽 / 背景任务 / 流式占位
    VM->>VM: useDSHAgentLoop ?
    VM->>D: runDSHTurn()
    D->>S: syncAgentHistoryIntoSession (按 seq 去重)
    D->>S: submitUserMessage(text)

    loop 每一步 (maxStepsPerTurn)
        D->>C: maybeCompact(turn)
        alt 表面 tokens ≥ 80% 窗口
            C->>S: 选范围 → 摘要 → appendCompaction
            S-->>D: DSHCompactionOutcome
            D-->>VM: didCompact → 渲染分隔行
        end
        D->>S: surfaceMessages()
        D->>P: buildRequest() → projectMessages()
        P-->>D: 流式 text / reasoning / tool-call
        D-->>VM: didEmitText / didEmitReasoning / willRunTool
        VM->>VM: dshMaybeFlushText（分级节流）
        VM->>VM: willRunTool 立刻建 tool block

        alt 有 tool-call
            D->>G: check(name, args) — 派发前
            G-->>D: pass / warning / critical
            Note over D,G: critical 不执行，理由作为工具结果回给模型
            D->>SC: execute(declared modes)
            SC->>SC: exclusive 成屏障，parallel 进有界池
            SC->>SC: 只跨连续已结算槽推进 → 提交顺序 = 模型顺序
            SC-->>D: [DSHToolCommit]
            D->>S: commitResult（assistant 的 tool-call + user 的 tool-result）
            D-->>VM: didFinishTool（按 callId 填 block）
            VM->>VM: dshRenderToolResult(callId)
        else 无 tool-call
            D->>S: 提交最终 assistant 消息（带 seq）
            D-->>VM: didEndTurn(reason)
        end
    end
    VM->>VM: dshSealStreamingTurn / persist
```

### 原时序的差别

| 环节 | 原来 | 现在 |
|---|---|---|
| 每轮起点 | `try Task.checkCancellation()` 后**重新按稳定 id 重锚 `msgIdx`**（`[T-ios-inloop-compact-freeze]`） | 不需要。seq 是不变量，不存在"重锚"这个动作 |
| 上下文检查 | 只在 `send()` 入口的 `checkContextBeforeSend()` + 循环内每轮重新评估 `ContextPolicy`（`.needsCompact` / `.exhausted`），压缩计数上限 `maxInLoopCompactions = 3` | `DSHTurnDriver.maybeCompact()` 一步，阈值 = 服务模型真实窗口的 80% |
| 工具结果回填 | `withTaskGroup` + `outcomesByIndex: [Int: ToolExecOutcome]`，之后 `guard let outcome = outcomesByIndex[idx] else { continue }` | `DSHSlotStore` + `commitReady()` 只跨连续槽推进，无索引可丢 |
| 工具 UI block | 结果挂在 `pendingSnapshots` / `toolStatusStrings`，靠二次遍历 `messages[msgIdx].blocks` 匹配 `toolUseId` | `willRunTool` 就建 block，`didFinishTool` 按 `callId` 填，别的路径抢不走 |
| 提示词 | 每个调用点 `baseSystemPrompt` 各拼一遍 + `capabilityPromptFragment` + `agentBehaviorPromptFragment` | `dshSystemPrompt` 有序 section 装配，运行时片段走 `context()` |

---

## 3. 会话身份：裸 Int 索引 → DSHSeq + shadow

这是整次移植里**唯一一个"删掉一整类 bug"**的改动，也是理解那 91 处补丁的钥匙。

```mermaid
flowchart TB
    subgraph BEF["原来：数组索引 = 身份"]
        direction TB
        bA["let idx = messages.count - 1<br/>loop 拿到 msgIdx"]
        bB["压缩插入分隔行"]
        bC["iCloud sync 整体重建"]
        bD["用户删除一条"]
        bE["messages.removeAll / insert"]
        bF["msgIdx 指向别的消息<br/>或越界"]
        bG["循环继续往一个已脱离数组的<br/>ChatMessage 里流式写入"]
        bH["UI 冻住，数据库却在前进"]
        bI["补丁：每个下标处重新按稳定 id 重锚<br/>T-ios-inloop-compact-freeze 等"]
        bB --> bE
        bC --> bE
        bD --> bE
        bE --> bF --> bG --> bH --> bI
        bA --> bF
        bI -. "每新增一处数组变更<br/>就要新增一处重锚" .-> bE
    end

    subgraph AFT["现在：seq = 身份，日志 append-only"]
        direction TB
        aA["DSHSession.log: [DSHLogEntry]<br/>永远只 append"]
        aB["每条带 DSHSeq（独立类型）<br/>无法与数组下标混用"]
        aC["压缩不删不改<br/>append 一条带 shadows 范围的摘要"]
        aD["surface() = 日志读穿过 shadow 集合"]
        aE["运行中的循环持有的 seq<br/>永远还指向同一条"]
        aF["ChatMessage.dshSeq / AgentMessage.dshSeq<br/>UI 随时能反查自己是谁"]
        aA --> aC --> aD --> aE
        aB --> aA
        aA --> aF
    end
```

### 为什么会有那 91 处补丁

`AIChatViewModel` 用**裸 `Int` 下标**寻址可变数组里的对话条目，而所有东西都能在 loop 运行期间改变这个数组：
压缩插入分隔行、iCloud 同步整体 `reloadMessagesFromDB`、用户删除、状态行 `removeAll`。

每一次变更都会让 loop 手里那个 `Int` 失效。失效的表现**不是崩溃而是静默**：loop 还在往一个已经不在数组里的 `ChatMessage` 写内容，屏幕不动，但数据库在前进。于是每个能被观察到的下标使用点都长出了一处"按稳定 id 重锚"的补丁。每一处单看都正确；合起来的意思是——**任何一处新增的数组变更，都要配套新增 N 处重锚**。

`DSHSession` 消掉的是这个类，而不是这些实例：

| 手段 | 效果 |
|---|---|
| 日志只 append，条目永不移动/替换/删除 | 没有"失效"这个状态 |
| `DSHSeq` 是独立类型（不是 `Int` 别名） | 编译期阻止把 seq 当下标用 |
| 压缩用追加的摘要**遮蔽**一段 seq 范围 | 运行中的 loop 持有的 seq 仍然有效 |
| `surface()` 是"日志穿过当前 shadow 集合"的派生视图 | 表面会变，日志不变 |
| `DSHToolPairing.cutBalances` / `nearestBalancedBefore` | 切点保证 tool call 与 result 不分离 |

最后一条对应原来的 `[T-ios-compact-orphan-toolcall]`：原来用**发送前扫描孤儿 tool part 再修补**（`AIChatViewModel+Persistence.swift:1506` 起）来兜底，现在是**切点根本不允许切在那里**。

---

## 4. 工具调度：cap + 索引缝合 → 声明式并发 + 连续提交

```mermaid
flowchart TB
    subgraph BEF2["原来"]
        direction TB
        c1["所有工具一律视为可并行<br/>static let maxConcurrentTools = 10"]
        c2["withTaskGroup<br/>addTask 时把 idx 一起带进去"]
        c3["outcomesByIndex: [Int: ToolExecOutcome]"]
        c4["for idx in 0..&lt;toolEntries.count<br/>guard let outcome = outcomesByIndex[idx]<br/>else { continue }"]
        c5["槽位没收割 → 结果被静默丢弃<br/>且没有任何日志"]
        c1 --> c2 --> c3 --> c4 --> c5
    end

    subgraph AFT2["现在"]
        direction TB
        d1["每个工具声明 .exclusive 或 .parallel<br/>DSHToolDispatch.mode(for:)"]
        d2["exclusive 成屏障<br/>（shell_execute / file_write / file_edit / memory_write）"]
        d3["parallel 进有界池<br/>maxParallelToolCalls = 4<br/>（file_read / read_image / memory_get）"]
        d4["DSHSlotStore.settle 写入槽<br/>commitReady 只跨连续已结算槽推进"]
        d5["提交顺序 = 模型顺序，由构造保证<br/>不存在 idx 可丢"]
        d1 --> d2
        d1 --> d3
        d2 --> d4
        d3 --> d4 --> d5
    end
```

三点实质差别：

1. **并发是数据，不是假设。** 原来"所有工具都可并行 + 一个 in-flight 上限"，等于假设工具之间没有共享状态。实际上 `shell_execute` / `file_write` / `file_edit` 都在动同一个沙箱。现在它们标 `.exclusive`，重叠执行从"靠运气"变成"不可能"。未知工具**默认 exclusive**——想并行必须显式声明，而不是默认继承。
2. **顺序由构造保证，而不是靠事后缝合。** 原来结果按 `idx` 存在字典里再按 `0..<count` 遍历回填，缺一个就 `continue` 掉。现在提交器只跨**连续已结算**的槽前进，模型顺序天然成立，且没有中间容器可以丢东西。
3. **守门在派发之前。** `DSHToolGate.check()` 在工具真正执行前跑：重复的无进展调用**不会执行**，理由是作为工具结果回给模型（`warning` / `critical` 两级 + 稳定 hash 归一化参数），而不是执行完再抱怨。

---

## 5. 压缩：marker / anchor / sortOrder → selectCompactableRange

```mermaid
flowchart TB
    subgraph BEF3["原来：AIChatViewModel+Compaction.swift（1084 行）"]
        direction TB
        e1["触发：ContextPolicy<br/>compactThreshold = contextWindow - 10000 / -20000"]
        e2["落点：lastCompactedMessageId marker<br/>+ sortOrder 排序 + UI 插入下标"]
        e3["marker.lcmId 在 rawMessages 里找不到<br/>→ orphaned，走 self-heal"]
        e4["self-heal 分支：<br/>v2(orphan→healByCreatedAt)<br/>compactAll(orphanedLcm→healByCreatedAt)<br/>compactAll(orphanedLcm→tailAnchor)"]
        e5["切点可能落在 tool_use 中间<br/>→ 发送前 couldRepair 扫描孤儿并修补"]
        e6["压缩是用户可见、可恢复、可撤销的操作<br/>（分隔行有 info 按钮、lcmId 可反解）"]
        e1 --> e2 --> e3 --> e4
        e2 --> e5
        e2 --> e6
    end

    subgraph AFT3["现在：DSHCompaction"]
        direction TB
        f1["触发：80% × 服务模型真实窗口<br/>窗口未知 → Int.max（禁用自动压缩，不猜）"]
        f2["选范围 selectCompactableRange：<br/>1. surface[0] 的 system 永不入范围<br/>2. 从尾部回溯累加 tokens 直到够 retainTokens<br/>3. 切点回溯到 tool-pairing 平衡位置<br/>4. 仅当摘要真比被替换内容便宜才落地"]
        f3["落地：append 一条 shadows: ClosedRange&lt;DSHSeq&gt; 的摘要条目"]
        f4["无 marker 需解析<br/>无 sortOrder 依赖<br/>切点结构性平衡 → 不会产生孤儿"]
        f5["保留：分隔行（ChatMessage.content 显式注记）<br/>revertLastCompaction() 可撤销"]
        f1 --> f2 --> f3 --> f4
        f3 --> f5
    end
```

### 阈值语义的差别（重要）

| | 原来 | 现在 |
|---|---|---|
| 触发点 | `窗口 - 10000`（大窗口）/ `窗口 - 20000` | `窗口 × 80%`（262144 → **209715**） |
| 窗口未知时 | 按 `ContextPolicy` 的默认分支 | **`Int.max` = 不自动压缩** |
| 循环内次数上限 | `maxInLoopCompactions = 3`，超过则"exhausted"停机 | 无人工上限；由"摘要必须真的更便宜"+"切点必须平衡"自然收敛 |
| 保留尾部 | 无显式预算，靠 marker 位置 | `retainTokens = 20000` |
| 落地条件 | 压缩成功即落地 | 摘要更便宜才落地，否则**拒绝** |

"窗口未知就不压缩"是一个刻意的选择：**把用户当前的请求压缩掉，比跑长一点更糟。**

### 实测数据（真机 iPhone 13 / iOS 15.3.1）

| | 压缩前 | 压缩后 |
|---|---|---|
| surface 条目 | 18 | **9** |
| 估算 tokens | 2026 | **1330** |
| 缩减 | — | **34%** |

同一轮里的 `shell_execute` 照常完成，压缩后模型仍能从摘要正确作答。算法另用 Python 等价实现（`_testdata/compaction_probe.py`）跑过合成表面：

| 场景 | 结果 |
|---|---|
| 20 × 20k 字符长工具输出 | 缩小 94%，切点平衡 |
| 图片块 | 缩小 73%，切点平衡 |
| 刚过阈值 | 缩小 45%，切点平衡 |
| retain 预算 > 整个表面 | 正确拒绝 |
| 会话太小 / 无 system 头 | 正确拒绝 |

---

## 6. 系统提示词：字符串拼接 → 有序 section 注册表

```mermaid
flowchart LR
    subgraph BEF4["原来"]
        direction TB
        g1["baseSystemPrompt: String<br/>一段巨大的字符串字面量"]
        g2["调用点 A: userSystemPrompt = baseSystemPrompt + cap + behavior"]
        g3["调用点 B: userSystemPrompt = baseSystemPrompt + cap + behavior"]
        g4["group fallback: userSystemPrompt = baseSystemPrompt + ..."]
        g1 --> g2
        g1 --> g3
        g1 --> g4
    end

    subgraph AFT4["现在"]
        direction TB
        h1["DSHSystemPrompt（有序注册表）"]
        h2["section(name, order, text, interpolate, complete)"]
        h3["context(name, order, text) — 运行时片段"]
        h4["variable(name, resolve) — 延迟求值"]
        h5["assemble(ctx) → 按 order 排序 + 插值 + 工具排序"]
        h6["renderPrompt(assembly) → String"]
        h1 --> h2 --> h5 --> h6
        h1 --> h3 --> h5
        h1 --> h4 --> h5
    end
```

- `{{variable}}` 是**严格**插值：`DSHSystemPrompt.interpolate` 按 UTF-16 code unit 扫描（`nextCloseBrace`），不认识的变量不会被静默吃掉。
- 三段内容分包：**基础内核段** `dshSystemPrompt`、**Minis 专属段** `DSHMinisPrompt.registerBase(into:)`（返回反注册闭包）、**运行时上下文** `DSHMinisPrompt.runtimeContextSection`（模型名 / provider / cwd / 工具名 / isHelper）。
- 反注册闭包让提示词是**资源而非全局状态**：注册即得 undo，作用域结束即干净。

---

## 7. 工具注册：手写字面量 → 注册表 + 类型化 schema

```mermaid
flowchart LR
    subgraph BEF5["原来：AIChatViewModel+ToolDefinitions.swift（199 行）"]
        direction TB
        i1["func makeAgentTools() -> [AgentToolDefinition]"]
        i2["逐条手写 name / description /<br/>parameters: [String: Any] 字面量"]
        i3["要改一个描述 → 在字面量里找<br/>要加一个工具 → 两处同步"]
        i1 --> i2 --> i3
    end

    subgraph AFT5["现在"]
        direction TB
        j1["DSHJSONSchema<br/>object / string / integer / boolean / array / number"]
        j2["DSHMinisTools.make(...) → [DSHTool]<br/>7 个工具：shell_execute · file_read · file_write ·<br/>file_edit · read_image · memory_write · memory_get"]
        j3["DSHToolRegistry<br/>register 返回反注册闭包 · schemas() · executionMode(name:)"]
        j4["DSHToolSchemaBridge<br/>DSHToolSchema → AgentToolDefinition（含 AgentParamType）"]
        j5["DSHToolDispatchBridge<br/>工具名 → DSHToolExecutionMode"]
        j1 --> j2 --> j3 --> j4
        j5 --> j3
    end
```

一点关键：**工具实现一行没改，而且不再被重新实现一遍。** 每个 `DSHTool` 的 body 直接调用 `executeSingleToolUse`——那是 Minis 完整的单次调用实现：流式输出写进块、图片预算、超长输出截断与 offload、loop detector、参数预检、工具快照。DSH 决定"什么时候跑"和"结果按什么顺序落盘"，不决定"这次调用做什么"。

### 工具面一致性

把调度换掉、把工具实现留下，就意味着**任何一处清单或参数的分歧，都是模型手里凭空少掉的能力**，而且不报错。这里踩过两次同一类坑，两次都是"抄了一份"：

| 坑 | 现象 | 现在的做法 |
|---|---|---|
| 抄了一份 schema | `dshAgentRegistry()` 和 `dshAgentTools()` 各手写一遍工具声明，两份都漏了 `browser_use` 和 iOS 26 线的 `subagent_task`——模型从未见过它们 | 名册来自 `makeAgentTools()`，`DSHMinisTools` 只负责把定义桥接成 `DSHTool`。**结构上不可能再漂移** |
| 抄了一份 handler | 适配器只挑自己认识的参数字段转发，`offset`/`lines`/`direction`/`max_length`/`create_dirs`/`delay` 全被吞掉，`read_image` 只回一句"图片 12 KB" | 执行走 `executeSingleToolUse`，参数整份转发 |

门控也只有一处：`makeAgentTools()` 是唯一知道内存开关、设置项开关、Vision Group、子代理开关的地方。

| 工具 | 门控 |
|---|---|
| `shell_execute` / `file_read` / `file_write` / `file_edit` | 总是注册 |
| `read_image` | `activeModelHasNativeVision \|\| VisionGroupResolver.isConfigured`（`[T-ios-vision-group #182]`） |
| `memory_write` / `memory_get` | `memoryEnabled` |
| `browser_use` | `Self.toolEnabled(.browser)` |
| `subagent_task`（仅 iOS 26 线） | `!isHelper && Self.toolEnabled(.agents)` |

`isConfigured` 必须在 `||` **之前**求值：短路会跳过这次读取，而这次读取正是维持 `isConfiguredCached` 镜像新鲜的来源（离屏占位构造依赖它）。

**工具结果不只是文本。** `read_image` 给模型的是图片，`browser_use` 给的是页面截图加落地 URL。这些字节挂在 **tool_result 这个 part 自己身上**（和原实现一致），不是单独一条消息——所以 `DSHToolResultBlock` 与 `DSHToolExecutionResult` 都带 `imageData` / `imageMimeType` / `pageURL` / `imageLinuxPath`，驱动在提交时写进去，投影时读出来。

```mermaid
flowchart LR
    A["工具参数 JSON<br/>（模型原样给出）"] --> B["DSHTool.body"]
    B --> C["dshExecuteMinisTool<br/>整份转发 + 定位调用块"]
    C --> D["executeSingleToolUse<br/>（Minis 完整实现）"]
    D --> E["流式输出 / 超长截断+offload<br/>图片预算 / loop detector / 快照"]
    D --> F["DSHToolExecutionResult<br/>content + imageData + pageURL"]
    F --> G["DSHTurnDriver.commitResult"]
    G --> H["DSHToolResultBlock<br/>（带图）"]
    H --> I["DSHSessionProjection<br/>→ AgentContentPart.toolResult"]
```

### 同一轮补齐的另外四个缺陷

这四个都是"验证 agent 全部能力"时才暴露出来的，不是顺手看到的：

**① 完全没有持久化。** `src/ios/DSH/` 里没有任何 `persistAgentMessage` 调用。DSH 模式下助手回复和工具结果**从不写进数据库**——屏幕上好好的，下次启动就没了，因为转录是从数据库重建的。现在每轮结束把本轮追加的条目写库（带本轮工具快照），并把数据库 id 回填到行上。

**② 工具结果被投影成 assistant 消息。** Minis 原 loop 把工具结果放在 **user** 消息里（`AgentMessage(role: .user, parts: toolResultParts)`），Anthropic 也要求 `tool_result` 不能出现在 assistant 轮里。原来的投影是 `role == .user ? .user : .assistant`，`.tool` 落进了 assistant——只因为 OpenAI 兼容路径宽容才没炸。

**③ loop guard 拿到的是空参数。** `gate.check(arguments: [:])` 意味着**同名工具的每次调用哈希都一样**：一轮里第 20 次 `file_read` 会被判成"重复调用"，它真实的返回被丢弃、换成一句拒绝。而且它在派发**之后**跑，本来就拦不住任何东西。现在按真实参数哈希、在调度前判定，被拒的调用也会先宣告一次，让它以工具自己的 block 头渲染。

**④ `propertyOrdering` 在 JSON Schema 往返里丢了。** 会用到它的 provider（Gemini）因此失去参数声明顺序。

### 分页修复的真机验证

`file_read` 的参数转发在 iPhone 13 / iOS 15.3.1 上实测过。一轮里让模型自己生成文件、再按范围读回：

| 步骤 | 工具块实际输出 |
|---|---|
| `shell_execute` 生成 200 行文件 | `/root/paging.txt` → 1692 bytes / 201 lines |
| `file_read`，`offset=100` + `lines=6` | `showing lines **100-105** of 201` |
| `file_read`，`direction=tail` + `lines=3` | `showing lines **199-201** of 201` |

修复前这两次读取都会返回 `showing lines 1-N of 201`——参数被适配器吞掉，schema 却还在对模型宣称可用。模型随后正确指出文件末尾多了一个空行，说明它读到的是真实的文件内容而不是记忆里的猜测。

证据：`shots/dsh-fix-02-paging.jpg`。




---

## 8. 文件清单与职责

### 新增（`src/ios/DSH/`，20 个 Swift 文件 + README）

| 文件 | 对应 DSH 源码 | 职责 |
|---|---|---|
| `DSHTypes.swift` | `packages/llm/llm/src/types.ts` | provider 中立词表：block / message / finish / failure / usage / schema / stream chunk |
| `DSHSystemPrompt.swift` | `packages/core/system-prompt/src/index.ts` | 有序 section 注册表、严格插值、装配与渲染 |
| `DSHToolRegistry.swift` | `packages/core/tools/src/index.ts` | 工具注册表、执行模式、参数解析、取消令牌 |
| `DSHToolScheduler.swift` | `packages/core/agent-loop/src/tool-calls.ts` | 声明式并发调度、连续槽提交 |
| `DSHToolGate.swift` | repeat-tool reminder + scheduler guards | 派发前守卫：重复 / 无进展 |
| `DSHSession.swift` | `packages/session` | append-only 日志、`DSHSeq`、shadow 表面、tool-pairing 平衡 |
| `DSHCompaction.swift` | `packages/compaction/compaction-basic/src/region.ts` | 选择规则、摘要落地、缩减比 |
| `DSHTurnDriver.swift` | `packages/core/agent-loop/src/agent.ts` | turn 循环、请求推导、结果落盘顺序 |
| `DSHJSONSchema.swift` | `packages/core/tools/src/json-schema.ts` | 类型化 JSON Schema 构造器 |
| `DSHToolSchemaBridge.swift` | — | `DSHToolSchema` → `AgentToolDefinition` |
| `DSHToolDispatchBridge.swift` | — | 工具名 → 并发模式（Minis 策略） |
| `DSHToolBlockKind.swift` | — | 工具名 + 参数 → `AssistantBlockKind` |
| `DSHMinisPrompt.swift` | — | Minis 专属提示词段 + 运行时上下文段 |
| `DSHMinisTools.swift` | — | Minis 工具定义 → `DSHTool`（schema 桥接，含 `propertyOrdering`） |
| `DSHPromptAdapter.swift` | — | 提示词入口 + `dshAgentTools()`（= `makeAgentTools()`）+ `useDSHAgentLoop` 开关 |
| `DSHTurnDriverRun.swift` | — | `runDSHTurn()`、阈值推导、session 同步、**持久化**、文本节流 |
| `DSHTurnDriverAdapter.swift` | — | `DSHTurnDriverDelegate` 实现、调用块创建、工具结果渲染、分隔行 |
| `DSHTurnDriverBridge.swift` | — | `DSHSessionProjection`（双向，含 role 映射）+ `DSHToolHandler` |
| `DSHToolHandlers.swift` | — | 按 `makeAgentTools()` 名册组装 `[DSHTool]` |
| `DSHToolHandlerImpl.swift` | — | 单次调用 → `executeSingleToolUse`（Minis 完整实现） |

### 修改（3 个源文件 + 工程文件）

| 文件 | 改动 |
|---|---|
| `src/ios/Agent/Chat/AIChatViewModel.swift` | +DSH 状态块（10 个属性）；3 个 `runAgentLoop()` 调用点分支；2 处 `private func` → `func`；工具集与提示词各 2 处改为条件取值 |
| `src/ios/Agent/Chat/ChatModels.swift` | `ChatMessage.dshSeq: Int?` |
| `src/ios/Providers/AgentProvider.swift` | `AgentMessage.dshSeq: Int?` |
| `src/ios/Minis.xcodeproj/project.pbxproj` | 新增 `PBXFileSystemSynchronizedRootGroup`，挂到 Minis target 的 `fileSystemSynchronizedGroups` |
| `.github/workflows/build-ipa.yml` | 双线构建（ios15 / ios26）+ 自动 Release + 构建前校验模块接入 |

### 未被改写（刻意）

`AIChatViewModel+Compaction.swift`（1084 行）、`+Persistence.swift`（1827 行）、`+ConcurrentTools.swift`、`+ToolDefinitions.swift`、`+SSEStream.swift`、`ContextPolicy.swift` 全部原样保留——当 `useDSHAgentLoop == false` 时它们仍然是对的路径，这就是 A/B 对比的基础。DSH 侧是**调用**它们，不是复制它们。

---

## 9. 开关与回退

```mermaid
flowchart TB
    K["AIChatViewModel.useDSHAgentLoop<br/>UserDefaults: minis.useDSHAgentLoop<br/>默认 true"]
    K -->|true| D1["runDSHTurn()<br/>DSH 内核：提示词 / 工具面 / 调度 / 会话 / 压缩 / turn 循环"]
    K -->|false| D2["runAgentLoop()<br/>原实现：baseSystemPrompt / makeAgentTools /<br/>withTaskGroup / agentHistory 裸索引 / +Compaction.swift"]
    D1 --> S["共享：流式呈现 · 持久化 · 图片预算 · UI · 工具实现（executeSingleToolUse）"]
    D2 --> S
```

- 开关是**类级静态属性**，不在会话或消息粒度上；同一进程内一致。
- 两个分支共用同一套持久化、UI 与工具实现，所以切换不会产生两套数据，也不会产生两种工具行为。
- 测试用阈值是**编译期**的（`dshCompactionProbeEnabled`），出厂值 `false`。原因是外部写 `UserDefaults` 无效：App 启动时注册自己的 defaults 字典并整份重写 plist，外部写入的 key 会被丢掉。

---

## 10. 移植到不同源码线的成本

| 层 | 需要改吗 | 说明 |
|---|---|---|
| `src/ios/DSH/` 20 个文件 | **原样复制** | 内核不认识 `AIChatViewModel`，只认识 DSH 词表 |
| 4 个 Bridge 文件 | 可能要适配 | 唯一接触 Minis 类型的地方（`AgentContentPart` 的 `toolResult` 关联值、`AssistantBlockKind` 的 case、`LLMUsage` 字段） |
| 3 个调用点 | 按上下文重贴 | 上游源码行号不同，要按局部上下文重新定位 |
| `dshSeq` 两个字段 | 各一行 | |
| pbxproj 分组 | 3 处编辑 | 父组必须无 `path =`，否则 `path = DSH` 解析到错目录，报 `cannot find dshSystemPrompt in scope` |

这就是为什么同一份内核对 iOS 15 线与 iOS 26 线能用同一套移植流程。
