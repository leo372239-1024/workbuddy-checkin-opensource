#!/bin/bash
# ============================================================
# 本地定时任务安装器（macOS / Linux）
#
# Windows 请改用 scripts/local-task.ps1（任务计划程序）。
#
# 用法：
#   bash scripts/local-cron.sh                 # 默认安装「每 10 天保鲜」一条
#   bash scripts/local-cron.sh --mode daily    # 只装每日补签（09/12/15/18/21 点）
#   bash scripts/local-cron.sh --mode both
#   bash scripts/local-cron.sh --remove        # 卸载本 skill 写入的所有条目
#   bash scripts/local-cron.sh --show          # 查看当前条目
#
# 实现说明：
#   - macOS/Linux 统一用 crontab（launchd 需要额外 plist，收益不大）。
#   - 通过标记注释 `# wb-checkin:<name>` 识别本 skill 的条目，卸载只删自己的，
#     不会动用户其它定时任务。
#   - cron 的 PATH 极简，脚本用绝对路径，且 checkin.sh 自带 node 探测兜底。
# ============================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wb-config.sh"
wb_load

MODE="refresh"
DAYS=10
AT_HOUR=12
AT_MIN=0
ACTION="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --at) AT_HOUR="${2%%:*}"; AT_MIN="${2##*:}"; shift 2 ;;
    --remove) ACTION="remove"; shift ;;
    --show) ACTION="show"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

command -v crontab >/dev/null 2>&1 || { echo "❌ 未找到 crontab（容器环境常见，请改用 systemd timer）"; exit 1; }

MARK="# wb-checkin"
TAG_REFRESH="$MARK:refresh"
TAG_DAILY="$MARK:daily"

current="$(crontab -l 2>/dev/null || true)"
stripped="$(printf '%s\n' "$current" | grep -v "$MARK:" || true)"

if [ "$ACTION" = "show" ]; then
  echo "当前本 skill 的定时条目："
  printf '%s\n' "$current" | grep "$MARK:" || echo "  （无）"
  exit 0
fi

if [ "$ACTION" = "remove" ]; then
  printf '%s\n' "$stripped" | sed '/^$/d' | crontab -
  echo "✅ 已移除本 skill 的定时条目"
  exit 0
fi

SCRIPT_DIR_M="$(wb_native_path "$WB_ROOT/scripts")"
LOGDIR="$WB_ROOT/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/cron.log"

new="$stripped"
add_line() { new="$(printf '%s\n%s\n' "$new" "$1")"; }

case "$MODE" in
  refresh)
    add_line "$AT_MIN $AT_HOUR */$DAYS * * /bin/bash '$SCRIPT_DIR_M/snapshot.sh' >> '$LOGFILE' 2>&1; /bin/bash '$SCRIPT_DIR_M/checkin.sh' >> '$LOGFILE' 2>&1 && /bin/bash '$SCRIPT_DIR_M/push-secret.sh' >> '$LOGFILE' 2>&1 $TAG_REFRESH"
    ;;
  daily)
    add_line "0 9,12,15,18,21 * * * /bin/bash '$SCRIPT_DIR_M/checkin.sh' >> '$LOGFILE' 2>&1 $TAG_DAILY"
    ;;
  both)
    add_line "$AT_MIN $AT_HOUR */$DAYS * * /bin/bash '$SCRIPT_DIR_M/snapshot.sh' >> '$LOGFILE' 2>&1; /bin/bash '$SCRIPT_DIR_M/checkin.sh' >> '$LOGFILE' 2>&1 && /bin/bash '$SCRIPT_DIR_M/push-secret.sh' >> '$LOGFILE' 2>&1 $TAG_REFRESH"
    add_line "0 9,12,15,18,21 * * * /bin/bash '$SCRIPT_DIR_M/checkin.sh' >> '$LOGFILE' 2>&1 $TAG_DAILY"
    ;;
  *) echo "❌ --mode 只能是 refresh / daily / both"; exit 1 ;;
esac

printf '%s\n' "$new" | sed '/^$/d' | crontab -
echo "✅ 已写入 crontab："
crontab -l | grep "$MARK:"
echo ""
echo "日志：$LOGFILE"
echo "提示：macOS 若提示「需要完全磁盘访问权限」，请在 系统设置 → 隐私与安全性 中"
echo "      给 cron（或 /usr/sbin/cron）授权，否则读不到 WorkBuddy 登录态。"
