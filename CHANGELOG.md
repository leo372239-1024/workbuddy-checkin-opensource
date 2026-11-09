# 变更日志

## [2.0.0] - 2026-11-09

### 重构：从「单机脚本」到「可分发部署包」

上一版是作者本机环境的说明书，别人拿到后要自己改路径、改 uid、猜账号。本版把「机器相关」与「逻辑」彻底分离。

### 新增

- **`scripts/wb-config.sh`**：配置读写库。所有机器相关值收敛到 `config.env`（已 gitignore），代码里不再出现任何 uid / 绝对路径 / 仓库名。
- **`scripts/wb-detect.sh`**：只读环境体检，输出人类可读报告 + `DETECT:KEY=VALUE` 机器行，退出码三态（0 可用 / 1 有告警 / 2 有硬阻塞）。Agent 据此决定下一步，而不是靠猜。
- **`scripts/init-config.sh`**：消费体检结果生成 `config.env`，与体检共用同一份判断，避免两套逻辑漂移。
- **`scripts/cloud-init.sh`**：一条命令在**用户自己的 GitHub 账号**下建私有仓库、渲染 workflow、写 Secrets、可选立即验证；带 `--dry-run` 只渲染不落地。
- **`scripts/local-task.ps1`**：生成 `.cmd` 并注册计划任务。强制 CRLF 并做字节级校验（LF 的 `.cmd` 会被 cmd.exe 静默空跑：任务显示成功、`LastTaskResult=0`、日志一条不生成）；自动注入 `HOME` / `PATH`（node/python/gh）/ `PYTHONUTF8` / `WB_CHECKIN_APP_EXE`——计划任务环境这四项全都缺。
- **`scripts/local-cron.sh`**：macOS/Linux crontab，用标记注释增删条目，不碰用户其它定时任务。
- **`scripts/snapshot.sh`、`scripts/push-secret.sh`**：由私有版泛化，保留原有选源纪律（当前登录态优先、按 `iat` 判新鲜、解出 uid 交叉校验防串号、网络异常不覆盖快照）。
- **`templates/cloud/`**：云端三件套（`checkin.py` / `notify.py` / `checkin.yml`），邮件告警通道去掉了个人邮箱默认值，未配置时自动降级为 GitHub Issue。

### 修正

- **账号歧义不再自动猜**：桌面端可能同时存在 `workbuddy-desktop.info` 与 `workbuddy-desktop-ai.info` 两份「当前登录态」且分属不同账号。旧逻辑取第一个命中的文件，会把 A 账号的令牌写进 B 账号的任务——表现为「签到一直成功，但积分进的是另一个号」。现在检测到多 uid 即拒绝自动选择，要求 `--uid` 显式指定。
- **桌面端可执行文件探测**：新增 `WORKBUDDY_APP_PATH` 反推与盘符根目录 `*workbuddy*` 兜底，修复「客户端装在非标准目录 → 信封解密失败 → 悄悄退化为搬历史明文快照」。
- **按实测修正令牌有效期认知**：旧版断言「滚动刷新只前移 `iat`、绝不后延 `exp`，硬到期只能靠重新登录」。2026-11-09 复测推翻：11-03 的令牌 `exp=12-03`，11-09 桌面端新令牌 `exp=12-09`，两者跨度均为整 30 天，说明重建会话时会给出完整新窗口。现表述为「两种都实测到过，不要往任何一端下结论」，并明确判有效性只认 `checkin-status` 的 HTTP 状态码。
- **Windows 脚本编码**：`.ps1` 改为 UTF-8 with BOM。PS 5.1 会把无 BOM 的 UTF-8 当 GBK 解析，中文注释直接导致语法崩溃。
- **`.gitignore` 目录锚定**：原 `cloud/` 规则会连 `templates/cloud/` 一起忽略，导致云端模板没能进版本库。

### 文档

- `SKILL.md` 重写为「首次部署协议」（六阶段 + 门禁）+「日常运维」+「核心认知」，每条纪律都标注了对应的事故形态。
- 新增 `references/dependencies.md` 引用；README 面向人类，给出「一句话安装」与手动路径。

## [1.3.0] - 2026-08-19

### 新增

- **「多账号彻底隔离与快照保鲜」章节**：文档化 WorkBuddy 多账号并存时的完整方案——登录态快照（`workbuddy-desktop.*.info` 历史文件即离线凭据源）+ `WB_CHECKIN_AUTH_FILE` 指定读取 + Secrets 后缀（`_2`）隔离 + 月度快照自动保鲜计划任务（`sync_snapshots.sh` + `WB-SnapshotSync-Monthly`）。明确 `auth/` 目录必须 gitignore（快照含 accessToken）。
- **浏览器登录态提取反面经验**：Chrome 130+ / Edge 新版 cookie 为 App-Bound Encryption（v20），解密需 SYSTEM 权限 + elevation_service 私钥，风险极高，**不要走这条路**；浏览器 Local Storage/IndexedDB 无 accessToken；实际凭据一律从桌面端快照获取。

### 修正

- 排错新增 5 条实战踩坑：多账号串号（任务名带 A 却签 B，根治 = 快照 + 独立 Secrets）、node 读 `/g/...` 路径 ENOENT（需 `cygpath -m`）、`require('*.info')` MODULE_NOT_FOUND（用 readFileSync）、浏览器 Cookies 文件占用（WinError 32，放弃 cookie 路线）、schtasks 输出 UTF-16 乱码（用 PowerShell 查询）。
- frontmatter `description` 补充多账号隔离/快照触发说明，版本升至 1.3.0。

## [1.0.5] - 2026-08-18

### 修正
- 更新「触发：创建云端 + 本地双保险签到任务」章节：云端默认时间由"中午 11:00"改为 **00:05 北京时间**（`5 16 * * *` UTC 前一日 16:05）；本地默认仍为 **11:00**（`BYHOUR=11;BYMINUTE=0`），分工为"云端 00:05 兜底关机场景 + 本地 11:00 本机补签/回传 token"。
- 新增**任务名账号后缀约定**：两个任务名（云端 workflow name + 本地自动化名）均带当前登录账号的 `account.nickname` 后缀（例如 `<账号名>`），明确 `account.uid` 仅用于云端 Secret、不作为任务名。
- frontmatter `description` 补充触发说明（云端 00:05 / 本地 11:00 / 账号名后缀）。

## [1.0.4] - 2026-08-18

### 新增

- **新增触发短语**：「为 workbuddy 目前登录的账号创建云端+本地自动签到任务」。命中时为**当前本机已登录的 WorkBuddy 账号**建立「云端 GitHub Actions + 本地 WorkBuddy 自动化」两个每天中午 11:00（北京，默认）的幂等签到任务，实现关机也能签。
- **新增「触发：创建云端 + 本地双保险签到任务」章节**：文档化完整流程——确认当前账号 → 云端 workflow（`cron` 设目标 UTC，默认 `0 3 * * *`）+ `sync_token.sh` 回传当前账号 Secrets → 本地 `automation_update` recurring 任务（默认 `BYHOUR=11;BYMINUTE=0`，prompt 含签到 + 回传）→ 校验。并明确「已存在同目标任务则改时间、不新建」的去重原则。

## [1.0.3] - 2026-08-12

### 修复

- **Windows 读不到新版明文登录态导致持续 401**（#73 / PR #74）：`decrypt-token.js` 的 win32 候选原本只探 `%APPDATA%\CodeBuddyExtension\...`，而当前桌面端实际把明文登录态写在 **`%LOCALAPPDATA%`**。读不到新文件时会回退旧版 `state.vscdb` 分支，取到**过期的历史会话令牌**，表现为「令牌能读出来、但接口一律 401」。现改为 **优先 `%LOCALAPPDATA%`、回退 `%APPDATA%`**。
  - **这是本次唯一修复 401 的改动。**

- **假 401 导致当日签到被跳过、连续签到中断**（`checkin.sh` / `checkin.ps1`，合并 PR #74 时发现）：401 判定原本是**扫响应体子串**（`grep -qi "401\|unauthorized"` / `$Status -match "401|unauthorized"`），而响应体带一个**每次随机的 UUID `requestId`**。UUID 里恰好出现 `401` 时，HTTP 200、`code=0` 的正常响应会被判成「令牌已过期」，脚本在调 `daily-checkin` **之前**就 `exit 1`。
  - **后果**：当日积分未领取；更贵的是**连续签到中断**，第 7 天的 1000 积分奖励作废。
  - **概率**：蒙特卡洛 20 万次实测 **0.566%/次**（理论 22/4096）。按每天跑一次计，**一年内约 87% 概率至少踩中一次**，期望每 177 天一次。
  - **修复**：改用 `curl -w '\n%{http_code}'` 取真实 HTTP 状态码，与响应体分离判定；`000`→网络异常、`401/403`→令牌失效、其他非 `200`→带状态码报错。日志从此能区分「网络异常 / 鉴权失败 / 业务失败」，便于事后诊断。
  - **验证**：4 例离线单测全绿（含「200 + requestId 含 401」这条关键用例，旧实现在此误判、新实现正确放行）；`checkin.sh` 端到端连跑 3 次均 `exit 0` 且幂等正确。

### 改进

- **请求签名对齐桌面端 `buildHeaders`**（`checkin.ps1`）：路径改用 `/v2/billing/meter/*`，并附带 `X-User-Id: <account.uid>`；有 `auth.domain` 时加 `X-Domain`，企业账号另加 `X-Enterprise-Id` / `X-Tenant-Id`。
  - **定位：前向兼容加固，不是 401 的修复项。** 网关当前并不强制这两项（见下方验证矩阵）。对齐上游的意义在于——官方哪天真收紧鉴权时，跟随桌面端的实现不会跟着挂。
- `decrypt-token.js` 在两处成功分支追加输出 `ACCOUNT_UID` / `AUTH_DOMAIN` / `ENTERPRISE_ID` 三行（纯 stdout，不落盘、不写日志），供调用方拼装鉴权头。
  - **调用方契约**：stdout 不再是单行，消费方**必须**按行前缀过滤（`grep '^DECRYPT_RESULT:'` / `Select-String`），不可整段捕获。现有 4 个消费方（`checkin.sh:79,87`、`setup.sh:55,136`、`checkin.ps1`、`setup.ps1:54,124`）均已是前缀过滤写法，无需改动。

### 根因更正（重要）

Issue #73 与 PR #74 原文断言「APISIX 网关只在 `/v2/billing/meter/*` 接受，**缺前缀直接 401**」「网关要求 `X-User-Id`，**缺此项同样 401**」。**这两条经实测证伪，不要据此排查后续 401。**

合并前用真实令牌跑的 2×2 只读验证矩阵（`checkin-status`，个人账号，macOS）：

| 组合 | 结果 |
|---|---|
| 旧 `/billing/meter` + 仅 `Authorization` | HTTP 200 `code=0 msg=OK` |
| 旧 `/billing/meter` + 完整头 | HTTP 200 `code=0` |
| `/v2/billing/meter` + 仅 `Authorization` | HTTP 200 `code=0` |
| `/v2/billing/meter` + 完整头 | HTTP 200 `code=0` |

写接口另行验证：`checkin.sh`（旧路径、不带 `X-User-Id`）实跑 `daily-checkin` 返回业务码 `code=10001`（今日已签到），**非 401**。

原实验之所以得出错误结论，是因为一次同时改动了三个变量（路径、请求头、**令牌来源**），而真正起作用的是第三个——手工 curl 用的是从 `%LOCALAPPDATA%` 现取的新鲜令牌。

**已知验证边界**：矩阵在个人账号（无 `enterpriseId`）、单一区域、单一时间点取得；企业账号或后续网关策略调整下的行为未覆盖。

### 文档

- `SKILL.md`：版本升至 1.0.3；原理章节补充 `/v2/` 与 `buildHeaders` 签名及其"非必要条件"的定位；平台表 Windows 行改为 `%LOCALAPPDATA%`（回退 `%APPDATA%`）；安全说明的网络访问范围补 `/v2/` 路径；排错新增「Windows 已登录却持续 401」条目，明确指向令牌来源而非请求构造。
- `decrypt-token.js`：恢复 PR #74 中被一并删除的维护性注释——跨平台登录态路径清单（并修正 Windows 为 `%LOCALAPPDATA%`）、依赖与运行方式、`emitAndExit` 延迟退出的原因、`app.setName` 必须早于 ready 的警告、python3 回退的信任边界说明。
- `checkin.ps1`：恢复 `today_checked_in` 字段不可靠的说明（它是 `code=10001` 幂等兜底存在的理由）、`ELECTRON_RUN_AS_NODE` 必须移除的原因、`WB_CHECKIN_JITTER` 用法说明。

### 已知限制

- `checkin.sh`（macOS / Linux）仍使用不带 `/v2/` 前缀、仅 `Authorization` 的旧写法。实测可用，故本版未改动；如需与桌面端完全对齐可后续收敛。
- Windows 侧（`%LOCALAPPDATA%` 路径修复、`/v2/` 签名、`checkin.ps1` 的 HTTP 状态码判定）**未在 Windows 实机验证**，本版验证均在 macOS 完成；以 PR #74 提交者与后续使用者反馈为准。

## [1.0.2] - 2026-08-06

### 修复

- **兼容 WorkBuddy 桌面端 v5.3.8 新版登录态存储**（#68）：v5.3.8 不再把当前登录态写入 `state.vscdb`，改用明文 JSON 文件 `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`（Windows/Linux 同构路径）。旧版（≤1.0.1）只认 `state.vscdb`，导致连续报「获取令牌失败（未知原因）」。
  - `decrypt-token.js` 改为**新版明文文件优先、旧版 `state.vscdb` 回退**；新版分支纯 Node 读取 `auth.accessToken`，无需 Electron `safeStorage` 解密。
  - `require("electron")` 包裹 try/catch，脚本可由普通 `node` 直接执行。
  - 统一 `emitAndExit()`（`process.stdout.write` 后延迟 ~200ms 退出），避免 `console.log` 后立即 `app.exit()` 导致 stdout 未 flush。
- **macOS 运行时策略改为 Node 优先**（#68）：直接调用 WorkBuddy.app 的 Electron 二进制会启动主应用而非执行脚本；新版明文文件用纯 Node 即可读取，无需依赖应用内 Electron。`checkin.sh`/`checkin.ps1`/`setup.sh`/`setup.ps1` 均改为 Node 优先、Electron 回退，新增 `WB_CHECKIN_NODE=<path>` 环境变量。
- **`daily-checkin` 的 `code=10001` 识别为已签到**（#68）：v5.3.8 实测 `checkin-status` 的 `today_checked_in` 不可靠（签到成功后仍为 `false`），当日重跑会再次调 `daily-checkin` 并返回 `code=10001`（今天已签到）；旧版将其误报为「签到未成功」，导致幂等分支失效。1.0.2 起正确报告「今日已签到，无需重复领取」。

### 改进

- 文档同步：`SKILL.md` / `references/dependencies.md` 更新原理、平台路径、依赖（Electron 降级为仅旧版可选）、环境变量（新增 `WB_CHECKIN_NODE`）、排错（v5.3.8 专项条目）。
- `setup.sh`/`setup.ps1`：v5.3.8 用户（仅 Node、无 Electron）不再被误判为「未找到 Electron」而失败。

### 合并前代码评审修复

- **`checkin.sh` / `checkin.ps1` Electron 回退条件修正（高）**：原实现仅当 Node 输出为空才回退 Electron；但旧版 `state.vscdb` 账户在装有 Node 的机器上，纯 Node 会输出非空的 `ERR`（无法解 safeStorage），导致 Electron 回退被跳过、误报失败（对 v1.0.1 旧版账户的回归）。改为「空 或 ERR」均回退。
- **`decrypt-token.js` 部分明文文件不再硬失败**：明文文件存在但缺 `auth.accessToken`（如升级中途 / 写入中）或解析失败时，不再 `exit 5`，而是落入旧版 `state.vscdb` 分支兜底。
- **`decrypt-token.js` 旧版读取异常可观测**：`readValue` 抛错（如 `node:sqlite` 不可用且未开 python3 回退）时不再裸抛，统一经 `DECRYPT_RESULT:ERR` 带原因输出，避免「未知原因」式失败。
- **`checkin.sh` `WB_CHECKIN_JITTER=0` / 非数字不再触发除零中止**：改为先 `[ -gt 0 ]` 校验。
- **`checkin.sh` 缺 `python3` 不再误报「签到未成功」**：结果解析为空时改为提示「请求已提交，缺 python3 无法解析」，避免服务端已成功却被报失败。

### 已知限制

### 已知限制

- Windows / Linux 的 `CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` 路径基于 v5.3.8 桌面端约定推导，已在 macOS 实测命中，其他平台待真实环境确认。

## [1.0.1] - 2026-08-05

### 改进

- 凭据安全：解密成功时向 stderr 输出安全提示（不污染 token 管道）；python3 回退默认关闭，需 `WB_CHECKIN_ALLOW_PY_FALLBACK=1` 启用
- 安装安全：`setup.sh`/`setup.ps1` 自动 `npm install electron` 默认关闭，需 `WB_CHECKIN_AUTO_INSTALL_ELECTRON=1` 才下载，默认提示手动指定路径并声明供应链风险
- 文档：SKILL.md 安全说明补强，新增「所需权限」清单与「为何需要这些能力」上下文说明，回应 SkillSpector 审计 findings

### 技术优化

- `checkin.sh`/`checkin.ps1` 头部注释补充凭据安全说明

## [1.0.0] - 2026-08-05

### 新增

- 初始版本：WorkBuddy 每日积分自动签到 skill 正式纳入 legal-skills 仓库
- 跨平台签到脚本：`scripts/checkin.sh`（macOS/Linux/Git Bash）与 `scripts/checkin.ps1`（Windows PowerShell，兼容 PS 5.1）
- 令牌解密脚本 `scripts/decrypt-token.js`：基于 Electron `safeStorage` 解密本地 `state.vscdb` 会话，`node:sqlite` 不可用时自动回退 `python3`
- 一键安装脚本 `scripts/setup.sh` / `scripts/setup.ps1`：自动检测或通过 npm 下载 Electron 运行时，并验证解密链路
- 多 Agent 框架适配（WorkBuddy 自动化任务 / Claude Code / Codex / OpenClaw / 纯终端），定时方式覆盖 crontab / launchd / schtasks / WorkBuddy recurring
- 幂等保护：每次运行先查 `checkin-status`，今日已签到立即跳过，支持一天多时间点补签（默认推荐 09/12/15/18/21 点）
- 随机错峰：`WB_CHECKIN_JITTER=<秒>` 环境变量让脚本启动前随机等待，避免整点风暴
- 兼容旧版应用名 CodeBuddy：`WB_CHECKIN_APP_NAME=CodeBuddy` 覆盖钥匙串绑定名

### 设计要点

- **全本机运行**：不含任何后端服务，令牌仅发往腾讯官方接口 `copilot.tencent.com`，不上传第三方
- **令牌不落盘**：仅在内存中传递；`logs/` 只记录签到结果（积分/连续天数），不含令牌
- **沙箱兼容**：WorkBuddy 等 Agent 沙箱默认设 `ELECTRON_RUN_AS_NODE=1` 会导致 `require('electron')` 拿不到 `safeStorage`，脚本已用 `env -u`（sh）/ `Remove-Item Env:`（ps1）显式处理

### 已知限制

- 签到按自然日结算，若整天未开机则当日无法补签，次日首个运行点自动重新开始（连续天数会重置）
- 令牌过期（401）需打开 WorkBuddy 桌面端刷新登录态，次日自动恢复
- macOS 应用名与钥匙串绑定：新装为 `WorkBuddy`，旧版迁移可能仍是 `CodeBuddy`

### 合规提示

- 本 skill 等价于「每天手动点一次领取今日礼包」，仅操作本机当前登录用户自己的 WorkBuddy 账户
- 请勿用于他人账户、批量注册刷分或任何违反 WorkBuddy 用户协议的用途
- 使用者需自行承担使用风险，确保来源可信
