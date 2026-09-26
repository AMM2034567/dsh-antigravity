# dsh-antigravity（本地修复版 fork）

这是 [LiZhenNet/dsh-antigravity](https://github.com/LiZhenNet/dsh-antigravity) **v0.0.4**
（commit `94957767c5e247d86cec8833fb1b67f659078af6`）的个人 fork，**只改了 `lib/index.js`**。

上游这两个问题都还没修，此仓库用于自用备份，方便 dsh profile 重装依赖后重新装回。

## 提交历史

| commit | 内容 |
|---|---|
| `558e4d4` | 上游 v0.0.4 **原始代码，未做任何修改**（保留它是为了能直接 `git diff` 出补丁）|
| `5749985` | 本地修复（见下）|

`upstream.patch` 就是这两个 commit 之间的完整 diff（只涉及 `lib/index.js`，76 行改动）。

---

## 修复 1：`CallId` 导出不存在 —— 插件根本无法加载

**症状**：`dsh web` 启动即崩：

```
Error: dsh: plugin tree failed to load: failed to import loader entry dsh-antigravity:
  The requested module '@deepseek-ai/dsh-llm' does not provide an export named 'CallId'

SyntaxError: The requested module '@deepseek-ai/dsh-llm' does not provide an export named 'CallId'
```

**原因**：`lib/index.js:15` 从 `@deepseek-ai/dsh-llm` 导入了 `CallId` 并把它当函数调用，
但**所有已发布版本导出的都是 `ToolCallId`，没有 `CallId`**。实测（下载 tarball 逐个校验）：

| dsh-llm 版本 | `CallId` | `ToolCallId` |
|---|---|---|
| `0.1.5-rc.3`（latest） | ❌ | ✅ |
| `0.1.7-rc.2`（next） | ❌ | ✅ |
| `0.1.7-alpha.2`（alpha） | ❌ | ✅ |

所以**升级 dsh 或更新插件都没用**。上游 `main` 分支（commit `9495776`）截至 2026-09-26 仍未修。

**修复**：`CallId` → `ToolCallId`（import 1 处 + 调用 2 处，约 15 / 1940 / 1952 行）。

语义正确而不是凑合：`ToolCallId` 正是 dsh-llm 中给 `ToolCallBlock.id`、
`ToolMessageSource.callId` 打品牌的函数，与 `CallId(toolId)` 的用法完全对应。

---

## 修复 2：issue #5 —— endpoint 回退与诊断能力

对应 [issue #5](https://github.com/LiZhenNet/dsh-antigravity/issues/5)（默认 endpoint 回退到 sandbox）。

1. **补上 daily endpoint**。官方客户端用的是
   `language_server --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com`，
   而插件原本只试 `cloudcode-pa` → `sandbox`，sandbox 会对很多地区直接返回 400。
   现在候选为 `[cloudcode-pa, daily, sandbox]`，sandbox 退到末位。
2. **记录每个候选 endpoint 的结果**。错误信息现在会带：

   ```
   attempts=[cloudcode-pa.googleapis.com=429 (RATE_LIMIT) > daily-cloudcode-pa.googleapis.com=400 (LOCATION_NOT_SUPPORTED)]
   ```
3. **区分地区限制**。新增错误码 `LOCATION_NOT_SUPPORTED`，并在 400 分支给出可操作提示。
4. **保留 `error.cause` 链**。原来只显示 `fetch failed`，现在会带
   `ETIMEDOUT` / `ECONNRESET` / `UND_ERR_CONNECT_TIMEOUT` 等 code。
5. **非流式请求加连接超时**（`postJson`，30s）。
6. `/antigravity-doctor` 增加 `lastAttempts=`。

### 实现时踩到的坑：`attempts` 必须按请求隔离

dsh 会在主回合之外**并发**发起一次「会话标题生成」的模型调用。如果把 `attempts` 存在模块级
全局数组里，两个请求会互相往同一个数组里塞，错误信息里就会出现
`cp, cp, daily, daily` 这种成对交错（而不是 `cp, daily`）。

现在的做法：`attempts` 是每次请求局部的数组，`diagnostics.attempts` 只保留最近一次的引用
给 `/antigravity-doctor` 用；错误里的 `endpoint=` 也从本请求 attempts 的末项推导，不再依赖全局状态。

---

## 实测结论：地区限制是「按后端分组」区分的

同一账号（中国大陆出口，`free-tier` 计划，`paidTier=g1-pro-tier / Google AI Pro`，配额显示 100% 未用）
逐一实发请求测试 11 个模型：

| 结果 | 模型 |
|---|---|
| ✅ 可用 | `claude-sonnet-4-6`、`claude-opus-4-6`、`gpt-oss-120b` |
| ⚠️ 返回 200 但无有效输出 | `gemini-3.5-flash`（正文就是 "Gemini 3.5 Flash is no longer available."）|
| ❌ `LOCATION_NOT_SUPPORTED` | `gemini-3.7-flash`、`gemini-3.6-flash`、`gemini-3.8-flash-tiered`、`gemini-3.1-pro`、`gemini-3.1-flash-image`、`gemini-3-flash`、`gemini-2.5-flash` |
| ❌ 429 / 503 链 | `gemini-2.5-pro`（`cp=429 > daily=503 > sandbox=503`）|

配额接口返回的是**两个互相独立的桶**：

```
group: Gemini Models          → Weekly / Five Hour
group: Claude and GPT models  → Weekly / Five Hour
```

> **Claude / GPT 那个桶走的后端不受这个地区限制，Gemini 那个桶受。**

所以在大陆出口下，把模型切到 Claude Sonnet/Opus 4.6 或 GPT-OSS 120B 就能直接用，
不必先换境外出口；只有想用 Gemini 系列才需要换出口。

注意：这和 issue #5 里报告的「sandbox 被拦、daily 能用」**恰好相反**，
说明限制是按「域名 × 后端 × 地区」组合生效的，不能一概而论。
另外 `cloudcode-pa` 返回的 429 在配额还剩 100% 时也会出现，那是地区拦截的伪装响应，
不要误判成配额耗尽。

---

## 怎么把本 fork 装回 dsh

**方式 A（推荐，重装依赖也不会丢）**：把 profile 的依赖指向本仓库。

编辑 `%USERPROFILE%\.dsh\profiles\web\package.json`：

```diff
   "dependencies": {
-    "dsh-antigravity": "github:LiZhenNet/dsh-antigravity"
+    "dsh-antigravity": "github:AMM2034567/dsh-antigravity"
   }
```

然后重装 profile 依赖并重启 `dsh web`。

**方式 B**：直接覆盖已安装的文件（会被下次重装覆盖）：

```powershell
Copy-Item .\lib\index.js "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-antigravity\lib\index.js" -Force
```

**方式 C**：把补丁打到新版插件上：

```powershell
git apply upstream.patch
```

---

## 上游状态（2026-09-26）

- `CallId` 导出名 bug：上游 `main` 未修，也没有任何 dsh 版本导出 `CallId` —— 属于插件自身写错。
- issue #5：上游未回应；其建议只覆盖「sandbox 被拦」这一种情况，未覆盖按后端分组的地区限制。

许可证沿用上游 MIT。
