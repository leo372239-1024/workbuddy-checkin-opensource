---
name: workbuddy-checkin
description: WorkBuddy 每日积分自动签到（开源版）。读取本机桌面端登录态（支持 v5.6+ $wbEncrypted 信封解密），调用腾讯官方签到接口领取每日积分（100/天，连续第 7 天 1000），并引导用户完成「云端 GitHub Actions + 本地定时任务」双保险部署。触发词：WorkBuddy 签到、每日积分、check-in、credits、自动签到、签到失败告警、token 过期、快照保鲜、按链接安装这个 skill。安装入口：用户发来 https://github.com/leo372239-1024/workbuddy-checkin-opensource 并要求安装时，按「首次部署协议」六阶段逐段执行，每阶段先说明再动手，阶段 3 未通过不得进入阶段 4/5。
version: "2.0.0"
license: MIT
---

# WorkBuddy 自动签到

自动领取 WorkBuddy 每日积分。本机读取登录态 → 调用腾讯官方接口，无第三方后端。

本 skill 有两种使用形态，**先判断属于哪一种**：

| 形态 | 判断依据 | 走哪里 |
|---|---|---|
| **A. 首次部署** | `config.env` 不存在，或用户刚发来安装链接 | 下面的「首次部署协议」 |
| **B. 日常运行 / 排错** | `config.env` 已存在 | 「日常运维」+「排错」 |

---

# 首次部署协议

> **执行纪律（对 Agent）**
> 1. **每阶段先告诉用户「现在做什么、为什么」，再执行**，不要一口气闷头跑完。
> 2. **阶段之间有门禁**：阶段 3 未通过（本地签不到），**禁止**进入阶段 4/5。云端只会放大错误。
> 3. **遇到阻塞就停下报告**，把原始错误贴给用户。不要静默降级、不要改用你自己的知识绕过。
> 4. **绝不打印、绝不写入日志**任何 `accessToken`。需要展示时只显示 uid 前 8 位与剩余天数。
> 5. **不要替用户决定账号与仓库名**。这些必须问出来。

## 阶段 0 · 安装 skill

**目标**：把仓库放到 Agent 的 skill 目录，让后续会话都能调用。

```bash
# 用户级（推荐，所有项目可见）
SKILL_DIR="$HOME/.workbuddy/skills/workbuddy-checkin"

if [ -d "$SKILL_DIR/.git" ]; then
  git -C "$SKILL_DIR" pull --ff-only        # 已装过 → 只更新
else
  mkdir -p "$(dirname "$SKILL_DIR")"
  git clone https://github.com/leo372239-1024/workbuddy-checkin-opensource "$SKILL_DIR"
fi
```

Windows 下的路径是 `%USERPROFILE%\.workbuddy\skills\workbuddy-checkin`，Git Bash 里 `$HOME` 已指向该目录。

**判定**：目录内存在 `SKILL.md`、`scripts/checkin.sh`、`scripts/wb-detect.sh`。
**失败**：网络不通时让用户手动下载 zip 解压到该目录，不要自己造脚本替代。

> 旧版 WorkBuddy/CodeBuddy（登录态在 `state.vscdb`）才需要额外装 Electron：
> `bash scripts/setup.sh`（macOS/Linux）或 `powershell -ExecutionPolicy Bypass -File scripts\setup.ps1`。
> 新版（v5.3.8+ 明文登录态）**跳过这步**。

## 阶段 1 · 环境体检（只读，不改任何东西）

```bash
cd "$SKILL_DIR" && bash scripts/wb-detect.sh
```

**读法**：末尾会输出 `DETECT:KEY=VALUE` 机器行与结论。
`退出码 0` = 全绿；`1` = 有告警可继续；`2` = 有硬阻塞，**必须停下**。

把 `[阻塞]` 项原文交给用户，并给出对应处置：

| 阻塞项 | 处置 |
|---|---|
| 未找到 Node.js | 装 Node 20+；或让用户在 `config.env` 写 `WB_NODE_BIN=<node 路径>` |
| 未找到登录态目录 | 打开 WorkBuddy 桌面端**登录一次**，再重跑 |
| 服务端返回 401 | 桌面端重新登录该账号，再重跑 |
| 登录态是加密信封但无 `APP_EXE` | 让用户确认安装路径，写 `WB_APP_EXE=<...>/WorkBuddy.exe` |

> 这一步会向腾讯接口发一次 `checkin-status`（只读查询，不领取）。若用户介意触网，加 `--no-net`。

## 阶段 2 · 生成本机配置

```bash
bash scripts/init-config.sh
```

它复用阶段 1 的探测结果写 `config.env`，**不覆盖已有值**（要覆盖加 `--force`）。
写入项：`WB_ACCOUNT_NAME` / `WB_ACCOUNT_UID` / `WB_ACCOUNT_FILE` / `WB_APP_EXE` / `WB_API_BASE`。

**判定**：`config.env` 存在，且 `WB_ACCOUNT_UID` 非空。
**注意**：该文件已 `.gitignore`，不要 `git add -f`。

## 阶段 3 · 本地跑通（门禁，必须成功）

```bash
bash scripts/checkin.sh
```

**通过标准**——日志里出现以下之一：

- `🎉 签到成功！领取 OK credit=100 streak_days=N`
- `✅ 今日已签到`

**不通过**的三种典型输出与含义：

| 输出 | 含义 | 处置 |
|---|---|---|
| `❌ 令牌已过期或无权限（HTTP 401/403）` | 令牌真失效 | 桌面端重新登录 → 重跑 |
| `❌ 查询签到状态失败（网络异常）` | 连不上接口 | 查代理/DNS；**这不代表令牌失效** |
| `❌ 获取令牌失败（...）` | 读不到登录态 | 回阶段 1 看 `[阻塞]` 项 |

**门禁**：只有这一阶段通过，才继续。云端部署会把本机问题放大成"每天静默失败"。

## 阶段 4 · 云端兜底（可选，需要 `gh`）

**先问用户三个问题**，不要替他决定：

1. **要不要云端兜底？** 好处：电脑关机也能签；代价：令牌会以 Secret 形式存在你 GitHub 账号里。
2. **仓库名用什么？** 默认 `<你的登录名>/workbuddy-checkin-cloud`（私有）。
3. **要不要失败邮件告警？** 需要提供 SMTP 服务器/端口/账号/授权码/收件人。

**如果用户不需要云端** → 直接跳到阶段 5，只装本地任务。

```bash
bash scripts/cloud-init.sh --verify      # --at 08:30 可改北京时间，默认 00:05
```

它做的事：`gh repo create`（私有）→ 铺模板 → 提交推送 → `gh secret set` 三件套 → 触发一次验证。

**必须在阶段 4 说清的两件事**（否则用户预期会错）：

- **Actions 定时任务会延迟 3~4 小时**。云端是"当天最后一道保险"，不是凌晨准点补签。
- **云端靠 Secret 里的令牌，令牌不会自己续期**。所以阶段 5 的保鲜任务不是可选项。

### 邮件告警（可选）

```bash
gh secret set MAIL_SMTP_HOST --repo <owner/repo> --body "smtp.example.com"
gh secret set MAIL_SMTP_PORT --repo <owner/repo> --body "465"
gh secret set MAIL_USERNAME  --repo <owner/repo> --body "you@example.com"
gh secret set MAIL_PASSWORD  --repo <owner/repo>   # 交互输入，不要回显、不要写进文件
gh secret set MAIL_FROM      --repo <owner/repo> --body "you@example.com"
gh secret set MAIL_TO        --repo <owner/repo> --body "you@example.com"
```

**不配就走 GitHub Issue 通道**（`notify.py` 自动降级，用内置 `GITHUB_TOKEN`，无需额外凭据）。
**校园/企业邮箱常封禁非内网 SMTP**，本机能发 ≠ Actions 能发。要验证就临时建一个 `workflow_dispatch` 自测 workflow，跑通后删掉。

## 阶段 5 · 本地保鲜任务（必装）

**为什么必装**：脚本能自动化的只有"把最新令牌搬运到 Secret"；能不能顺带续期取决于桌面端是否重建会话，脚本无法保证。
**没有这个任务，云端会在令牌到期那天静默失效，而本地日志一切正常。**

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\local-task.ps1 -Mode refresh -Days 10 -At 12:00
```

macOS / Linux：

```bash
bash scripts/local-cron.sh --mode refresh --days 10 --at 12:00
```

生成物（Windows）：`local/update_token.cmd` + 计划任务 `WB-Refresh-<账号>`。
`.cmd` 里已自动配好 `HOME`、`PATH`（node/python/gh）、`PYTHONUTF8`、`WB_CHECKIN_APP_EXE`，**不要手改**——改完需重跑安装器。

> 如果用户还需要"本地每日补签"（例如没有 GitHub 账号），加 `-Mode both` 或多跑一次 `-Mode daily`。
> **不要同时装本地每日任务和云端每日任务之外的第三份调度**（如 WorkBuddy 自动化），会重复触发。

## 阶段 6 · 验收

逐项确认，**不要只看退出码**：

| # | 检查 | 命令 | 通过标准 |
|---|---|---|---|
| 1 | 配置齐全 | `cat config.env` | `WB_ACCOUNT_UID` 非空 |
| 2 | 本地签到 | `bash scripts/checkin.sh` | 出现「签到成功」或「今日已签到」 |
| 3 | 快照落地 | `ls auth/` | 有 `<账号>.info`，且 `grep -c accessToken` = 1 |
| 4 | Secret 已写 | `gh secret list --repo <owner/repo>` | 含 `WORKBUDDY_ACCESS_TOKEN` |
| 5 | 云端可跑 | `gh run list --repo <owner/repo> --limit 1` | 最近一次 `success` |
| 6 | 本地任务已装 | `schtasks /Query /TN WB-Refresh-<账号>` 或 `crontab -l` | 任务存在，`NextRunTime` 正确 |
| 7 | 任务真能跑 | `schtasks /Run /TN WB-Refresh-<账号>` → 等 20s → 看 `logs/update_token.log` | 日志有新内容且无 401 |

**第 7 项最容易被跳过，也最容易被骗**：`.cmd` 行尾是 LF 时，任务会显示成功、`LastTaskResult=0`、日志一条不生成。安装器已强制 CRLF 并做字节校验，但**必须实际跑一次看日志**。

---

# 日常运维

```bash
bash scripts/wb-detect.sh          # 一眼看全：能不能签、令牌还剩几天、云端最近状态
bash scripts/checkin.sh            # 签到一次（幂等，随便跑）
bash scripts/snapshot.sh           # 保鲜：搬最新令牌到 auth/<账号>.info
bash scripts/push-secret.sh        # 回传：把令牌写到 GitHub Secret
bash scripts/push-secret.sh --dry-run   # 只校验凭据可读，不推送
```

**令牌到期后（收到告警邮件时）的标准两步**：

1. 桌面端用该账号**重新登录**（或完全退出后重启，触发新会话）——这是唯一能推后到期日的动作。
2. `bash scripts/snapshot.sh && bash scripts/push-secret.sh`

**改造任何脚本前先问一句**：「这个脚本除了签到，还在替谁做什么？」
本项目最容易踩的坑是"只刷新本地快照、忘记推 Secret"——保鲜白做且无人察觉。

# 核心认知（决定所有判断，别凭直觉）

### 1. 保鲜 ≠ 续期，但"会不会续"取决于服务端签发方式

| 观测到的情形 | 证据 | 行为 |
|---|---|---|
| 会话内滚动续签 | 10-24：桌面态 `iat` 比快照新 46.9 小时，`exp` 反而**早** 1.1 小时 | 刷新**不**后延 `exp` |
| 重新建立会话 | 11-09：`iat` 前移 6 天，`exp` 同步前移 6 天（两者均 `iat + 30 天`） | 新会话给**满 30 天** |

两种都实测到了，所以**不要往任何一端下结论**：

- 不要向用户承诺"任务会自己续期"——存在不续期的那种情况。
- 也不要笃定"到某天必然过期"——重新建立会话时到期日会前移。
- **唯一可靠的判据是 `checkin-status` 的 HTTP 状态码**，不是 `exp`。
- 保鲜任务的价值不变：确保云端持有的是**当前有效**令牌；如果桌面端恰好建立了新会话，顺带把到期日推后。
- 正因为"可能不续期"，失败告警不能省。

### 2. 新鲜度按 `iat` 判，不能按 `expiresAt`

判据：当前登录态（文件名无时间戳）→ 令牌不同即覆盖；历史快照 → 仅当 `cand.iat > cur.iat` 才覆盖。

用 `expiresAt` 比较会把**刚刷新的令牌**判为陈旧而拒收——因为滚动续签时新令牌的 `exp` 可能比旧令牌更早。
（上面的证据表第二行是 `exp` 前移的情况，第一行是 `exp` 不变/更早的情况，两种都会遇到。）

### 3. 幂等只认业务码 `code=10001`

`checkin-status` 的 `today_checked_in` 字段实测不可靠（签完仍可能 `false`）。
`daily-checkin` 在"今日已签到"时返回 **HTTP 400 + code=10001**，所以**不能把 HTTP≠200 当失败**，必须以响应体业务码为准。

### 4. 网络异常 ≠ 令牌失效

| 情况 | 含义 | 动作 |
|---|---|---|
| `HTTP 401/403` | 令牌真失效 | 跳过该候选，继续下一个 |
| 连不上（超时/DNS/代理） | **无法判定** | 中止，明确报错，**不覆盖**现有快照 |

把网络异常当 401，会把所有候选判死然后降级覆盖成更旧的令牌。
**"测不出来"绝不能当成"可以用"。**

### 5. 只有 `HTTP 200` 才算健康

空输出、未知状态码、加密信封一律**不计为健康**。健康检查要三态退出码（0 全好 / 1 有失效 / 2 测不全），二值表达不了"测不出来"。

### 6. 云端 cron 不是准点

Actions 定时任务实测延迟 3~4 小时。它是"当天最后一道保险"，不是"凌晨准点补签"。

# 本机配置项（config.env）

| 键 | 含义 | 谁写 |
|---|---|---|
| `WB_ACCOUNT_NAME` | 展示名/任务名后缀 | `init-config.sh` |
| `WB_ACCOUNT_UID` | 账号 uid，防串号锚点 | `init-config.sh` |
| `WB_ACCOUNT_FILE` | `auth/<名>.info` 快照文件名 | `init-config.sh` |
| `WB_APP_EXE` | 桌面端可执行文件（信封解密必需） | `init-config.sh` 探测 |
| `WB_API_BASE` | 官方接口地址 | 默认 `https://copilot.tencent.com` |
| `WB_SECRET_SUFFIX` | 多账号时 Secrets 后缀（`_2`） | 用户/`--force` |
| `WB_CLOUD_REPO` | `owner/repo` | `cloud-init.sh` |
| `WB_CLOUD_DIR` | 云端仓库本地目录 | `cloud-init.sh` |

环境变量（临时覆盖，不写配置）：
`WB_CHECKIN_AUTH_FILE`（指定登录态文件）、`WB_CHECKIN_APP_EXE`、`WB_NODE_BIN`、`WB_API_BASE`、`WB_AUTH_DIR`（测试用）、`WB_CHECKIN_JITTER=<秒>`（错峰）、`WB_DRY_RUN=1`（告警只打印不发送）。

# 多账号

桌面端是**单账号登录态**，切换会覆盖。多账号隔离靠两件事：

1. 每个账号一份**规范化快照** `auth/<账号>.info`，脚本用 `WB_CHECKIN_AUTH_FILE` 指定。
2. 每个账号一组 **Secret 后缀**（第二账号 `_2`），workflow 各引用各的。

步骤：改 `config.env` 的 `WB_ACCOUNT_UID` / `WB_ACCOUNT_FILE` / `WB_SECRET_SUFFIX` → 跑 `snapshot.sh` → `push-secret.sh` → `cloud-init.sh --repo <第二仓库>`。
**验证隔离**：两边的 `snapshot.sh` 输出里 uid 必须不同，云端两个 workflow 日志里 `WB_RESULT` 各自独立。

# 排错

- **`登录态为 $wbEncrypted 加密信封，但未找到 WorkBuddy 桌面端可执行文件`**：设 `WB_APP_EXE`。计划任务环境下 `WORKBUDDY_APP_PATH` 不继承，必须写进 `config.env` 或 `.cmd`（安装器已代劳）。
- **交互式手跑成功，计划任务跑出来"来源=历史快照"**：同上，`WB_APP_EXE` 没传进任务环境。判定看日志里的来源标注，不是退出码。
- **`schtasks /Run` 显示成功、`LastTaskResult=0`、日志一条没有**：`.cmd` 是 LF 行尾，cmd.exe 直接空跑。重跑 `local-task.ps1`（会强制 CRLF 并字节校验）。
- **`.cmd` 日志中文乱码**：缺 `chcp 65001` 或 `PYTHONUTF8=1`，安装器已内置。
- **`node -e` 报 `Illegal return statement`**：Node 22 不允许顶层 `return`，用 `if/else` 包裹。
- **`read` 用 tab 作 `IFS` 导致行错位**：tab 是 IFS 空白字符，连续分隔符会被折叠。用 `\x1f`。
- **`node` 读 `/g/...` 报 `ENOENT`**：node.exe 只认 `G:/...`。脚本内已统一 `cygpath -m`。
- **`.sh` 被改成 CRLF 后比较/排序异常**：`\r` 混进变量值。`.gitattributes` 已固定 `.sh → LF`。
- **云端到点没跑，晚了几小时**：Actions 排队延迟，不是配置错。看 `gh run list` 的 `created_at` 差值。
- **告警说"已签到"却仍在报错**：`today_checked_in` 不可信，以 `daily-checkin` 的业务码为准。
- **token `expiresAt` 还没到却 401**：服务端可能已提前作废（refreshToken 轮换等）。别只看 `expiresAt`，用 `checkin-status` 的 HTTP 状态码判。
- **git push 报 `Connection was reset`**：先试直连，再试本地代理
  `git -c http.proxy=http://127.0.0.1:7897 push`；两者都失败用 `gh api user` 区分"网络断了"还是"git 的 TLS 问题"。
  另一种常见根因是 TLS 1.3 握手被中间链路破坏，可试 `git -c http.sslVersion=tlsv1.2 push`。

# 安全红线

- `accessToken` = 账号密码。**不进日志、不回显、不提交**。
- 唯一落盘位置：`auth/<账号>.info`（已 `.gitignore`）。该目录不得同步到任何网盘/云盘。
- 网络请求只发往 `copilot.tencent.com`。
- `config.env`、`auth/`、`logs/`、`local/`、`cloud/` 全部被忽略，**不要 `git add -f`**。
- 只用于用户自己的账号；不要实现批量注册/刷分。
- 运行前如用户对"读取登录态"有疑虑，明确告知：**不读这个令牌就无法调用签到接口，这是签到的唯一实现路径**，且读取全程在本机、无上传。

# 平台差异

| 平台 | 签到脚本 | 新版明文登录态（v5.3.8+，主路径） | 旧版 `state.vscdb`（回退） |
|---|---|---|---|
| Windows | `checkin.sh`（Git Bash）或 `checkin.ps1` | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`（回退 `%APPDATA%`） | `%APPDATA%\WorkBuddy\User\globalStorage\state.vscdb` |
| macOS | `checkin.sh` | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/Library/Application Support/WorkBuddy/User/globalStorage/state.vscdb` |
| Linux | `checkin.sh` | `~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/.config/WorkBuddy/User/globalStorage/state.vscdb` |

旧版回退分支在 Linux 需要桌面会话 + 系统 keyring；新版明文分支无此要求。

# 环境变量

临时覆盖用，不写进 `config.env`：

| 变量 | 作用 |
|---|---|
| `WB_CHECKIN_AUTH_FILE` | 指定登录态文件（多账号隔离 / 指向规范化快照） |
| `WB_CHECKIN_APP_EXE` | 桌面端可执行文件路径（`$wbEncrypted` 信封解密必需） |
| `WB_NODE_BIN` | 指定 node 路径（缺 PATH 时用） |
| `WB_API_BASE` | 接口地址，默认 `https://copilot.tencent.com` |
| `WB_AUTH_DIR` | 覆盖登录态目录（仅测试/造故障样本用） |
| `WB_CHECKIN_JITTER` | 启动前随机等待 0~N 秒，避免整点风暴 |
| `WB_DRY_RUN=1` | 告警脚本只打印不发送 |
| `WB_CHECKIN_NODE` / `WB_CHECKIN_ELECTRON` | 指定运行时（旧版回退分支用） |

# 权限与披露

本 skill 运行所需的本地权限，均限定在最小范围：

| 权限 | 范围 | 说明 |
|---|---|---|
| 本地代码执行 | 仅本仓库 `scripts/` 下的脚本 | 手动或定时触发，非常驻后台 |
| 本地文件读取 | 用户目录下的 WorkBuddy 登录态文件 | 只读；唯一写入是 `auth/<账号>.info`（已 gitignore） |
| 网络访问 | 仅 `copilot.tencent.com` 官方接口；云端部分访问 `api.github.com` | 不访问任何其他域名 |
| Secrets 写入 | 用户自己指定的 GitHub 仓库 | 经 `gh secret set`，token 走 stdin，不进命令行历史 |
| 定时任务 | 由安装器显式注册，可一条命令卸载 | 不偷装、不隐藏 |

### 为什么必须读登录令牌

WorkBuddy 桌面端登录后把登录态存放在本地，签到接口要求 `Authorization: Bearer <accessToken>`。
**不读这个令牌就无法调用签到接口——这是签到的唯一实现路径，没有替代方案。**
读取全程在本机完成，不上传任何第三方；脚本会把这一点打印在 stderr 便于随时确认。

### 供应链

- 旧版账户才需要 Electron，且**默认不自动下载**。需要时须显式设置 `WB_CHECKIN_AUTO_INSTALL_ELECTRON=1`，从官方 npm registry 拉取 `electron@37`（约 100MB）。
- 新版账户（v5.3.8+）**完全不需要 Electron**，纯 Node 即可。
- 本仓库不包含任何混淆代码、不引入第三方 pip/npm 依赖，云端只依赖 Python 标准库。

# 卸载

```bash
# 1. 删定时任务
powershell -ExecutionPolicy Bypass -File scripts\local-task.ps1 -Remove   # Windows
bash scripts/local-cron.sh --remove                                       # macOS/Linux

# 2. 删云端（可选）
gh repo delete <owner/repo> --yes

# 3. 删 skill
rm -rf "$HOME/.workbuddy/skills/workbuddy-checkin"
```
