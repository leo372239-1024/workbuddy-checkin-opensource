# WorkBuddy 每日积分签到

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey.svg)]()

自动领取 **WorkBuddy** 每日积分（**100 积分/天，连续第 7 天 1000 积分**）的本地签到脚本。全流程在本机完成：读取本地登录态 → 调用腾讯官方签到接口，**无任何后端服务**。

> 本仓库是 [workbuddy-checkin](https://github.com/) WorkBuddy 技能的开源版本，已移除所有个人身份信息，可直接分发使用。

## ✨ 特性

- **纯本机运行**：令牌仅在内存中使用，不落盘、不回显、不写日志
- **新版明文登录态直读**：WorkBuddy v5.3.8+ 用 Node 直接读明文 `workbuddy-desktop.info`，**无需 Electron**
- **旧版回退**：旧版 `state.vscdb`（Electron `safeStorage` 加密）自动回退
- **多账号彻底隔离**：登录态快照 + `WB_CHECKIN_AUTH_FILE` 指定 + Secrets 后缀隔离
- **幂等设计**：一天多时间点补签无副作用，随机错峰避免整点风暴

## 🔍 原理

1. WorkBuddy 桌面端登录后本地保存登录态。**v5.3.8+ 新版**为明文 JSON 文件：
   - macOS：`~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`
   - Windows：`%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`
   - 结构 `{ account, auth: { accessToken, refreshToken, expiresAt, ... } }`
2. **旧版** WorkBuddy/CodeBuddy 用 Electron `safeStorage` 加密存于 `state.vscdb`，新版文件缺失时回退到此路径解密。
3. 调用腾讯官方签到 API：
   - 查状态：`POST https://copilot.tencent.com/v2/billing/meter/checkin-status`
   - 执行签到：`POST https://copilot.tencent.com/v2/billing/meter/daily-checkin`
   - 认证：`Authorization: Bearer <accessToken>` + `X-User-Id: <account.uid>`

## 📁 目录结构

```
workbuddy-checkin-opensource/
├── SKILL.md                    # WorkBuddy 技能说明（含完整踩坑经验）
├── CHANGELOG.md                # 变更日志
├── references/
│   └── dependencies.md         # 依赖清单与平台差异
└── scripts/
    ├── decrypt-token.js        # 解密令牌（跨平台）
    ├── checkin.sh              # macOS / Linux / Git Bash
    ├── checkin.ps1             # Windows PowerShell
    ├── setup.sh                # macOS / Linux 一键安装
    └── setup.ps1               # Windows 一键安装
```

## 🚀 快速开始

macOS / Linux：
```bash
bash scripts/setup.sh     # 检测运行时并验证令牌链路
bash scripts/checkin.sh   # 立即签到一次（验证）
```

Windows（PowerShell）：
```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
powershell -ExecutionPolicy Bypass -File scripts\checkin.ps1
```

前置条件：本机已安装并**登录** WorkBuddy 桌面端；系统已安装 Node.js（v5.3.8+ 主路径）。

## 📦 依赖

| 依赖 | 用途 | 说明 |
|------|------|------|
| WorkBuddy 桌面端（已登录） | 提供本地登录态 | v5.3.8+ 明文 / 旧版 `state.vscdb` |
| Node.js（20+） | 读取新版明文登录态 | v5.3.8+ 主路径必需 |
| curl | 调用签到 API | macOS/Linux 自带；Windows 10 1803+ 自带 |
| Electron 运行时 | **仅旧版** `state.vscdb` 解密 | 仅旧版账户需要 |

> v5.3.8+ 用户：装好 Node.js 并登录桌面端即可直接签到，**无需 Electron**。

## ⏰ 定时任务

### Windows（任务计划程序）

```powershell
schtasks /Create /TN "WB-DailyCheckin-11" /TR "<你的项目路径>\daily_checkin.cmd" /SC DAILY /ST 11:00 /F
schtasks /Create /TN "WB-DailyCheckin-21" /TR "<你的项目路径>\daily_checkin.cmd" /SC DAILY /ST 21:00 /F
```

> 建议用 `.cmd` 入口脚本（内含 `HOME`/`PATH`/`PYTHONUTF8`/`chcp 65001` 等配置）。

### macOS / Linux（crontab）

```bash
0 9,12,15,18,21 * * * /path/to/scripts/checkin.sh >> /path/to/logs/checkin.log 2>&1
```

## 👥 多账号隔离

WorkBuddy 桌面端是**单账号登录态**，多账号并存需用「登录态快照 + `WB_CHECKIN_AUTH_FILE` 指定」方案：

1. 桌面端每次登录会在 auth 目录留存带时间戳的 `workbuddy-desktop.<ts>.<pid>.<uuid>.info` 快照，复制各账号快照到仓库 `auth/<账号>.info`
2. 设 `WB_CHECKIN_AUTH_FILE=<快照路径>` 指定读取对应账号
3. 云端 Secrets 用后缀隔离（`WORKBUDDY_ACCESS_TOKEN` vs `_2`）

完整流程见 `SKILL.md` 的「多账号彻底隔离与快照保鲜」章节。

## ☁️ 云端签到（可选，关机也能签）

fork 本仓库 → 设为**私有** → 配置 GitHub Actions + Secrets（`WORKBUDDY_ACCESS_TOKEN` / `WORKBUDDY_UID` / `WORKBUDDY_DOMAIN`），由本机定时回传 token 保鲜。完整流程见 `SKILL.md`。

## 🔑 环境变量

| 变量 | 作用 |
|------|------|
| `WB_CHECKIN_NODE=<path>` | 指定 Node 二进制路径 |
| `WB_CHECKIN_ELECTRON=<path>` | 指定 Electron 二进制路径（仅旧版） |
| `WB_CHECKIN_APP_NAME=CodeBuddy` | 兼容旧版应用名（仅旧版 macOS 钥匙串） |
| `WB_CHECKIN_JITTER=<秒>` | 启动前随机等待 0~N 秒 |
| `WB_CHECKIN_AUTH_FILE=<path>` | **多账号隔离**：指定登录态 JSON 文件 |

## ⚠️ 安全说明

> **凭据即账号密码**：解密的 `accessToken` 等同你的 WorkBuddy 账号密码。

- 令牌仅在内存中使用，通过管道立即被签到请求消费，不落盘、不回显、不提交仓库
- `logs/` 仅记录签到结果，绝不含令牌原文
- 网络访问仅发往腾讯官方接口 `copilot.tencent.com`
- **请勿用于他人账户、批量注册刷分或任何违反用户协议的用途，使用者自行承担风险**

## 📄 License

[MIT](./LICENSE)
