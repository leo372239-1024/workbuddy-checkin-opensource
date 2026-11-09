# WorkBuddy 自动签到（开源版）

每天自动领取 WorkBuddy 每日积分（100 积分/天，连续第 7 天 1000 积分）。
**全流程在本机与你自己 GitHub 私有仓库内完成，没有第三方服务器，凭据不离开你。**

> 这是一个 [Agent Skill](https://www.workbuddy.cn/docs/workbuddy/Overview)。它不是给你手敲命令的，而是让**你的桌面 Agent** 读完 `SKILL.md` 后，一步步引导你完成部署。

## 一句话安装

把下面这句话发给你自己的桌面 Agent（WorkBuddy / CodeBuddy 等支持 Skill 的客户端）：

```
根据链接安装并运行这个 skill：https://github.com/leo372239-1024/workbuddy-checkin-opensource
```

Agent 会依次做：克隆到 skills 目录 → 环境体检 → 生成本机配置 → 跑通一次签到 → （可选）创建你的私有云端仓库 → 装好本地定时任务。
每个阶段都会先告诉你要做什么、再执行，遇到阻塞会停下来问，不会自己乱猜。

## 它解决什么问题

| 场景 | 没有它 | 有它 |
|---|---|---|
| 每天手动开客户端签到 | 忘一天就断连续 | 定时任务幂等执行，重复跑无副作用 |
| 电脑关机 | 当天漏签 | 云端 GitHub Actions 兜底（延迟 3~4 小时，属正常） |
| token 过期 | 静默失效，连续签到中断 | 失败即告警邮件 + GitHub Issue 双通道 |
| 多账号 | 相互覆盖、串号 | 每个账号独立快照 + 独立 Secret 后缀 |

## 架构

```
桌面端登录态 ──► 快照保鲜 ──► auth/<账号>.info ──► 幂等签到（本地）
   ($wbEncrypted)   (按 iat 选源)        │
                                        └──► GitHub Secrets ──► Actions 每日签到（云端）
                                                                    └─失败─► 邮件 / Issue
```

两条通道互相独立：本地负责「拿到最新令牌并回传」，云端负责「即使你关机也能签」。

## 环境要求

- WorkBuddy 桌面端，且**已登录至少一次**
- Node.js 20+（读取登录态、解析 JWT）
- Windows 10+ / macOS 12+ / Linux
- 可选：`gh` CLI（配置云端任务）、Python 3（签到结果明细解析）

## 手动使用（不想用 Agent 时）

```bash
git clone https://github.com/leo372239-1024/workbuddy-checkin-opensource ~/.workbuddy/skills/workbuddy-checkin
cd ~/.workbuddy/skills/workbuddy-checkin

bash scripts/wb-detect.sh        # 体检：能不能签、令牌还剩几天
bash scripts/init-config.sh      # 写 config.env
bash scripts/checkin.sh          # 签到一次（幂等）
```

云端与定时任务：

```bash
bash scripts/cloud-init.sh --verify   # 创建私有仓库 + 写 Secrets + 验证
bash scripts/local-cron.sh            # macOS/Linux 定时
powershell -ExecutionPolicy Bypass -File scripts\local-task.ps1   # Windows 定时
```

## 安全边界

- 令牌（`accessToken`）等同账号密码。它只在内存中流转，**不进日志、不回显、不提交**。
- 唯一的落盘位置是 `auth/<账号>.info`（已 `.gitignore`），用于让下游脚本摆脱桌面端依赖。
- 全部网络请求只发往 `copilot.tencent.com` 官方接口。
- 云端 Secret 通过 `gh secret set` 从 stdin 写入，不出现在命令行历史里。
- 请只用于**你自己的账号**。批量刷分等违反用户协议的行为不在本项目支持范围内。

## 许可

MIT。使用风险自负，与 WorkBuddy 官方无关。
