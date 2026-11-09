#!/bin/bash
# ============================================================
# 把本机令牌回传到 GitHub 仓库 Secrets（云签约定的凭据通道）
#
# 为什么需要这一步：云端 GitHub Actions 无法读取你的本地登录态，
# 只能靠 Secret 携带的 accessToken 签到。**只要这一步断了，云端最迟在
# token 到期那天静默失效**——而本地日志一切正常，极难察觉。
#
# 用法：
#   bash scripts/push-secret.sh                 # 推到 config.env 里的 WB_CLOUD_REPO
#   bash scripts/push-secret.sh owner/repo      # 指定仓库
#   bash scripts/push-secret.sh --dry-run       # 只校验凭据可读，不推送
#
# 安全：token 通过 stdin 交给 gh，不出现在命令行参数、不打印、不落盘。
# ============================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wb-config.sh"
wb_load

DRY=0
REPO_ARG=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) REPO_ARG="$a" ;;
  esac
done

REPO="${REPO_ARG:-${WB_CLOUD_REPO:-}}"
if [ -z "$REPO" ]; then
  echo "❌ 未指定仓库。请先在 config.env 设置 WB_CLOUD_REPO=owner/repo，或作为参数传入"
  exit 1
fi

SUFFIX="${WB_SECRET_SUFFIX:-}"
SECRET_TOKEN="WORKBUDDY_ACCESS_TOKEN${SUFFIX}"
SECRET_UID="WORKBUDDY_UID${SUFFIX}"
SECRET_DOMAIN="WORKBUDDY_DOMAIN${SUFFIX}"
SECRET_EID="WORKBUDDY_ENTERPRISE_ID${SUFFIX}"

# ---- 定位解密脚本与登录态 ----
DECRYPT_JS="$WB_ROOT/scripts/decrypt-token.js"
[ -f "$DECRYPT_JS" ] || { echo "❌ 缺少 scripts/decrypt-token.js，仓库不完整"; exit 1; }
DECRYPT_JS="$(wb_native_path "$DECRYPT_JS")"

# 优先用规范化快照（保鲜产物），没有则退回桌面当前登录态
AUTH_FILE="${WB_CHECKIN_AUTH_FILE:-}"
if [ -z "$AUTH_FILE" ] && [ -n "${WB_ACCOUNT_FILE:-}" ] && [ -f "$WB_ROOT/auth/$WB_ACCOUNT_FILE" ]; then
  AUTH_FILE="$WB_ROOT/auth/$WB_ACCOUNT_FILE"
fi
[ -n "$AUTH_FILE" ] && AUTH_FILE="$(wb_native_path "$AUTH_FILE")"

NODE_BIN="$(wb_find_node)"
[ -n "$NODE_BIN" ] || { echo "❌ 未找到 node（请安装 Node.js 20+ 或设置 WB_NODE_BIN）"; exit 1; }

OUT="$(WB_CHECKIN_AUTH_FILE="$AUTH_FILE" WB_CHECKIN_APP_EXE="${WB_APP_EXE:-}" "$NODE_BIN" "$DECRYPT_JS" 2>&1)"
TOKEN="$(printf '%s' "$OUT" | grep '^DECRYPT_RESULT:' | sed 's/^DECRYPT_RESULT://')"
UID_VAL="$(printf '%s' "$OUT" | grep '^ACCOUNT_UID:' | sed 's/^ACCOUNT_UID://')"
DOMAIN_VAL="$(printf '%s' "$OUT" | grep '^AUTH_DOMAIN:' | sed 's/^AUTH_DOMAIN://')"
EID_VAL="$(printf '%s' "$OUT" | grep '^ENTERPRISE_ID:' | sed 's/^ENTERPRISE_ID://')"

if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
  echo "❌ 读取 accessToken 失败：${TOKEN#ERR }"
  echo "   排查顺序：桌面端是否登录 -> WB_APP_EXE 是否指向桌面端可执行文件"
  exit 1
fi

# 防串号：解出的 uid 与配置的目标账号必须一致
if [ -n "${WB_ACCOUNT_UID:-}" ] && [ -n "$UID_VAL" ] && [ "$UID_VAL" != "$WB_ACCOUNT_UID" ]; then
  echo "❌ 串号保护触发：解出的 uid=$UID_VAL 与配置的 WB_ACCOUNT_UID=$WB_ACCOUNT_UID 不一致"
  echo "   已中止，未推送任何 Secret（否则云端会用错账号签到）"
  exit 1
fi

DAYS="$(wb_days_left "$TOKEN")"
echo "🔑 待回传凭据：uid=${UID_VAL:0:8}... 剩余 ${DAYS} 天  ->  $REPO"

if [ "$DRY" = "1" ]; then
  echo "（--dry-run）凭据可读、uid 校验通过；未推送。"
  exit 0
fi

GH_BIN="$(wb_find_gh)"
[ -n "$GH_BIN" ] || { echo "❌ 未找到 gh CLI（https://cli.github.com/ ，或 gh auth login 后重试）"; exit 1; }

if printf '%s' "$TOKEN" | "$GH_BIN" secret set "$SECRET_TOKEN" --repo "$REPO" >/dev/null 2>&1; then
  echo "✅ 已回传 accessToken -> $SECRET_TOKEN"
else
  echo "❌ 回传失败（检查 gh 登录态与仓库写权限：gh auth status）"
  exit 1
fi

push_opt() {
  local name="$1" val="$2"
  [ -z "$val" ] && return 0
  if printf '%s' "$val" | "$GH_BIN" secret set "$name" --repo "$REPO" >/dev/null 2>&1; then
    echo "✅ 已回传 -> $name"
  else
    echo "⚠️  $name 回传失败（忽略，不影响签到）"
  fi
}
push_opt "$SECRET_UID" "$UID_VAL"
push_opt "$SECRET_DOMAIN" "$DOMAIN_VAL"
push_opt "$SECRET_EID" "$EID_VAL"

echo ""
echo "提示：Secret 更新后，云端下一次定时任务即使用新令牌。"
echo "      可用 gh workflow run 手动触发一次立即验证。"
