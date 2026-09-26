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
7. **网络层失败不再只报 `fetch failed`**：`fetchStreamResponse` 现在把 Undici 的 `TypeError`
   包成 `LlmError(code=TRANSPORT)` 并带上完整的 `error.cause` 链，会直接显示 `ETIMEDOUT`
   （原来 `code=undefined`、消息只有 `fetch failed`，完全无法定位）。
8. **不可达时继续试下一个 endpoint**：原来第一个域名网络不通就整体放弃，
   现在会继续尝试后续候选（调用方的中止信号仍正确冒泡）。
9. **无 HTTP 响应时给出网络层提示**：提示检查连接 / 代理 / DNS。

### 实现时踩到的坑：`attempts` 必须按请求隔离

dsh 会在主回合之外**并发**发起一次「会话标题生成」的模型调用。如果把 `attempts` 存在模块级
全局数组里，两个请求会互相往同一个数组里塞，错误信息里就会出现
`cp, cp, daily, daily` 这种成对交错（而不是 `cp, daily`）。

现在的做法：`attempts` 是每次请求局部的数组，`diagnostics.attempts` 只保留最近一次的引用
给 `/antigravity-doctor` 用；错误里的 `endpoint=` 也从本请求 attempts 的末项推导，不再依赖全局状态。

---

## 实测结论（修正版）：地区限制只看**出口 IP**，与模型分组无关

> ⚠️ 这一节最初写成「Claude/GPT 桶不受地区限制、Gemini 桶受」。**那个结论是错的**，
> 之所以保留修正过程，是因为它很容易被误判。

### 直连（系统代理关闭）时

| 结果 | 模型 |
|---|---|
| ✅ 可用 | `claude-sonnet-4-6`、`claude-opus-4-6`、`gpt-oss-120b` |
| ❌ `LOCATION_NOT_SUPPORTED` | `gemini-3.7-flash`、`gemini-3.6-flash`、`gemini-3.8-flash-tiered`、`gemini-3.1-pro`、`gemini-3.1-flash-image`、`gemini-3-flash`、`gemini-2.5-flash` |
| ❌ 429 / 503 | `gemini-2.5-pro` |

看起来很像「Gemini 桶被拦」，但那只是巧合 —— 那次探测里 Claude 的请求恰好走了能通的链路。

### 走代理（受支持地区出口）后重测

```
OK    gemini-3.7-flash / gemini-3.6-flash / gemini-3.1-pro / gemini-3.1-flash-image
OK    gemini-3-flash / gemini-2.5-flash / gemini-3.8-flash-tiered
OK    claude-sonnet-4-6 / claude-opus-4-6 / gpt-oss-120b
FAIL  gemini-2.5-pro   code=QUOTA
```

**11/12 可用** —— 之前报 `LOCATION_NOT_SUPPORTED` 的 Gemini 模型全部通过。

### 真正的结论

- 地区限制**只看出口 IP 的归属地**，与模型属于哪个配额桶无关。
- 配额确实分两个桶（`Gemini Models` / `Claude and GPT models`），但那是**计费分组**，
  不是地区策略的边界。
- `cloudcode-pa` 在配额还剩 100% 时也可能返回 429 —— 那是地区拦截的伪装响应，
  不要误判成配额耗尽（本次 `gemini-2.5-pro` 的 429/QUOTA 才是真的配额问题）。

### 复现方式

在 `~/.dsh/profiles/web/` 放一个 `.mjs`：

```js
import { AntigravityAdapter, FileCredentialStore, FileModelSettingsStore } from 'dsh-antigravity';
const a = new AntigravityAdapter(new FileCredentialStore(), new FileModelSettingsStore());
for await (const c of a.stream({ model, messages, maxTokens, signal })) { /* ... */ }
```

跑的时候记得带上代理环境变量，否则一律 ETIMEDOUT（见下一节）。

> 注意：`maxTokens` 给太小（比如 24）时，thinking 类模型会把预算全花在推理上，
> 返回 `(empty)` —— 那是探测参数的问题，不代表模型不可用。

---

## 怎么把本 fork 装回 dsh

**方式 A（当前实际在用的方案）**：装本地 tarball。

```powershell
cd D:\cargoproject\dsh-antigravity
.\pack-local.ps1                 # 打包 dist/*.tgz 并装进 web profile
```

profile 的 `package.json` 会变成：

```json
"dsh-antigravity": "file:D:/cargoproject/dsh-antigravity/dist/dsh-antigravity-0.0.4.tgz"
```

> **为什么不用 `github:` 依赖**：pnpm 解析 `github:` 要跑
> `git ls-remote https://github.com/...`，而这台机器上 `github.com:443` 经常超时
> （`codeload.github.com` / `api.github.com` 却是通的）。本地 tarball 完全不依赖网络，
> 顺带也绕开了 git-hosted 包的 `allowBuilds` 白名单问题。
>
> 代价：**改完 `lib/*.js` 必须重跑 `pack-local.ps1`**，否则 profile 用的还是旧 tarball。

**方式 A'**：如果哪天 `github.com` 通了，也可以直接指向本仓库：

```diff
-    "dsh-antigravity": "github:LiZhenNet/dsh-antigravity"
+    "dsh-antigravity": "github:AMM2034567/dsh-antigravity"
```

**方式 B**：直接覆盖已安装的文件（会被下次重装覆盖）：

```powershell
Copy-Item .\lib\index.js "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-antigravity\lib\index.js" -Force
```

**方式 C**：把补丁打到新版插件上：

```powershell
git apply upstream.patch
```

---

## 运行：必须先让 Node 走代理，否则一律 `fetch failed`

**这是最容易踩的坑，而且报错极具误导性。**

症状：所有模型调用失败，错误就是 `fetch failed`，`code=undefined`，
看起来像被墙或插件 bug，实际上只是代理没生效。

根因：**Node 的 `fetch`（undici）完全不读 Windows 系统代理，也不读 PAC**，只认环境变量；
而且 Node ≤23 即使设了 `HTTPS_PROXY` 默认也会忽略。实测（Node v24.14.1）：

```
node fetch 直连                                    → ETIMEDOUT
node fetch + HTTPS_PROXY（不开开关）                → ETIMEDOUT
node fetch + HTTPS_PROXY + NODE_USE_ENV_PROXY=1     → 200  ✅
```

> 打开系统「使用代理服务器」开关**没有用**，配 PAC 也**没有用**。
> 只有 TUN / 全局模式（网络层透明拦截）才能绕过这个限制。

所以本仓库提供 `start-web.ps1`：

```powershell
.\start-web.ps1 -OpenBrowser
.\start-web.ps1 -Proxy http://127.0.0.1:7890      # 换代理端口
.\start-web.ps1 -Profile tui -Port 3081
```

它设置：`HTTP_PROXY` / `HTTPS_PROXY` / `NODE_USE_ENV_PROXY=1` /
`NO_PROXY=localhost,127.0.0.1,registry.npmmirror.com,cdn.npmmirror.com`
（最后一项是把国内镜像排除掉，否则 pnpm 会被绕进代理，变慢甚至失败）。

如果不想用脚本，也可以把 `NODE_USE_ENV_PROXY=1` 和 `HTTPS_PROXY` 设成用户级环境变量，
但那会影响**所有** Node 程序（对你其他 AI CLI 多半是好事，但属于全局改动）。

---

## 上游状态（2026-09-27）

- `CallId` 导出名 bug：上游 `main` 未修，也没有任何 dsh 版本导出 `CallId` —— 属于插件自身写错。
- issue #5：上游未回应。它提的「不要把 sandbox 当默认回退目标」方向是对的，
  但报告里「sandbox 被拦、daily 能用」只是**出口 IP 差异**造成的巧合 ——
  本次实测同一台机器上两类 endpoint 的表现会随网络出口反转。
- 上游还缺一件事：网络层失败时只报 `fetch failed`，丢掉了 `error.cause` 里的
  `ETIMEDOUT` / `ECONNRESET`，导致很难区分「被墙」「代理没生效」「服务端故障」。

许可证沿用上游 MIT。
