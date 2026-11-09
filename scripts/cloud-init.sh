#!/bin/bash
# ============================================================
# 云端签到仓库一键初始化（GitHub Actions）
#
# 做什么：在**你自己的 GitHub 账号**下创建一个私有仓库，放入签到脚本与 workflow，
#         把本机令牌写进 Secrets，然后推送。之后云端每天定时签到，
#         电脑关机也不影响。
#
# 用法：
#   bash scripts/cloud-init.sh                       # 默认 <你的登录名>/workbuddy-checkin-cloud
#   bash scripts/cloud-init.sh --repo me/my-checkin  # 指定仓库名
#   bash scripts/cloud-init.sh --at 08:30            # 指定北京时间（默认 00:05）
#   bash scripts/cloud-init.sh --verify              # 建完立即手动跑一次验证
#   bash scripts/cloud-init.sh --dir /path/to/repo   # 指定本地工作目录
#
# 幂等：仓库已存在时不会重建，只更新文件与 Secrets。
# ============================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wb-config.sh"
wb_load

REPO=""; AT_BJ="00:05"; VERIFY=0; CLOUD_DIR=""; VISIBILITY="--private"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --at) AT_BJ="$2"; shift 2 ;;
    --dir) CLOUD_DIR="$2"; shift 2 ;;
    --public) VISIBILITY="--public"; shift ;;
    --verify) VERIFY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

GH_BIN="$(wb_find_gh)"
[ -n "$GH_BIN" ] || { echo "❌ 未找到 gh CLI。请先安装：https://cli.github.com/"; exit 1; }

# ---- 0. 校验 gh 登录态 ----
if ! "$GH_BIN" auth status >/dev/null 2>&1; then
  echo "❌ gh 未登录。请先执行：gh auth login"
  echo "   需要 repo 权限（创建私有仓库 + 写 Secrets）"
  exit 1
fi
LOGIN="$("$GH_BIN" api user --jq .login 2>/dev/null)"
[ -n "$LOGIN" ] || { echo "❌ 无法读取 GitHub 用户名（网络或凭据问题）"; exit 1; }
echo "✅ GitHub 账号：$LOGIN"

[ -z "$REPO" ] && REPO="${WB_CLOUD_REPO:-$LOGIN/workbuddy-checkin-cloud}"
REPO_NAME="${REPO#*/}"
[ -z "$CLOUD_DIR" ] && CLOUD_DIR="${WB_CLOUD_DIR:-$WB_ROOT/cloud}"

# ---- 1. 北京时间 -> UTC cron ----
CRON_UTC="$(WB_AT="$AT_BJ" "$(wb_find_node)" -e '
  const s=(process.env.WB_AT||"00:05").trim();
  const m=/^(\d{1,2}):(\d{2})$/.exec(s);
  if(!m){console.error("时间格式应为 HH:MM");process.exit(1);}
  let mins=Number(m[1])*60+Number(m[2]);
  if(mins<0||mins>=1440){console.error("时间超出范围");process.exit(1);}
  let u=mins-480; if(u<0)u+=1440;
  const hh=String(Math.floor(u/60)).padStart(2,"0"), mm=String(u%60).padStart(2,"0");
  process.stdout.write(`${mm} ${Number(hh)} * * *`);
')" || { echo "❌ --at 参数无效"; exit 1; }
set -- $CRON_UTC
UTC_LABEL="$(printf '%02d:%02d' "$2" "$1")"
echo "⏰ 北京时间 $AT_BJ  ->  cron $CRON_UTC（UTC $UTC_LABEL）"
echo "   注意：Actions 定时任务实测排队延迟 3~4 小时，属正常现象"

# ---- 2. 账号名（workflow 展示与日志用） ----
ACCOUNT="${WB_ACCOUNT_NAME:-}"
if [ -z "$ACCOUNT" ]; then
  NODE_BIN="$(wb_find_node)"
  ACCOUNT="$(WB_F="$WB_ROOT/auth/${WB_ACCOUNT_FILE:-}" "$NODE_BIN" -e '
    const fs=require("fs");let o="";
    try{const j=JSON.parse(fs.readFileSync(process.env.WB_F,"utf8"));
      const n=j.account&&j.account.nickname;o=typeof n==="string"?n:"";}catch(e){}
    process.stdout.write(o);
  ' 2>/dev/null)"
fi
[ -z "$ACCOUNT" ] && ACCOUNT="$LOGIN"
SLUG="$(wb_slug "$ACCOUNT")"
[ -z "$SLUG" ] && SLUG="account1"
echo "👤 账号标识：$ACCOUNT（slug=$SLUG）"
wb_set WB_ACCOUNT_NAME "$ACCOUNT"

# ---- 3. 铺模板 ----
mkdir -p "$CLOUD_DIR"
cp "$WB_ROOT/templates/cloud/checkin.py" "$CLOUD_DIR/checkin.py"
cp "$WB_ROOT/templates/cloud/notify.py" "$CLOUD_DIR/notify.py"
mkdir -p "$CLOUD_DIR/.github/workflows"
cp "$WB_ROOT/templates/cloud/.github/workflows/checkin.yml" "$CLOUD_DIR/.github/workflows/checkin.yml"

# 占位符替换（用 python 做，避免 sed 的跨平台转义差异）
WB_YML="$CLOUD_DIR/.github/workflows/checkin.yml" WB_ACC="$ACCOUNT" WB_SLUG="$SLUG" \
WB_CRON_UTC="$CRON_UTC" WB_CRON_BJ="$AT_BJ" WB_CRON_UTC_LABEL="$UTC_LABEL" "$(wb_find_node)" -e '
  const fs=require("fs");
  const p=process.env.WB_YML;
  let s=fs.readFileSync(p,"utf8");
  s=s.split("__ACCOUNT_NAME__").join(process.env.WB_ACC)
     .split("__ACCOUNT_SLUG__").join(process.env.WB_SLUG)
     .split("__CRON_UTC__").join(process.env.WB_CRON_UTC)
     .split("__CRON_UTC_LABEL__").join(process.env.WB_CRON_UTC_LABEL)
     .split("__CRON_BJ__").join(process.env.WB_CRON_BJ);
  fs.writeFileSync(p,s,"utf8");
'

cat > "$CLOUD_DIR/README.md" <<EOF
# WorkBuddy 云端自动签到（$ACCOUNT）

由 [workbuddy-checkin](https://github.com/leo372239-1024/workbuddy-checkin-opensource) 生成。

- \`checkin.py\`：调用腾讯官方签到接口，幂等（今日已签到不会重复领取）
- \`notify.py\`：仅失败时告警，邮件优先、回退 GitHub Issue
- \`.github/workflows/checkin.yml\`：每日北京时间 $AT_BJ 定时触发

## 凭据怎么来

Secret \`WORKBUDDY_ACCESS_TOKEN\` 由本机脚本写入，**不经过这个仓库**。
令牌到期后需在本机重新登录 WorkBuddy 桌面端，再运行：

\`\`\`bash
bash scripts/snapshot.sh && bash scripts/push-secret.sh
\`\`\`

## 手动触发

Actions -> WorkBuddy Daily Checkin -> Run workflow
EOF

cat > "$CLOUD_DIR/.gitignore" <<'EOF'
checkin.log
__pycache__/
*.pyc
EOF

# ---- 4. 提交并创建仓库 ----
if [ "$DRY" = "1" ]; then
  echo ""
  echo "（--dry-run）模板已渲染到：$CLOUD_DIR"
  echo "  目录内容："
  find "$CLOUD_DIR" -type f | sed "s|^$CLOUD_DIR/|  |"
  echo ""
  echo "  渲染后的 workflow 关键行："
  grep -E '^(name:|    - cron:|      - name:)' "$CLOUD_DIR/.github/workflows/checkin.yml" | sed 's/^/    /'
  echo ""
  echo "未创建仓库、未推送、未写 Secrets。去掉 --dry-run 即真实执行。"
  exit 0
fi

cd "$CLOUD_DIR" || exit 1
if [ ! -d .git ]; then
  git init -q
  git checkout -q -b main 2>/dev/null || git branch -q -m main 2>/dev/null || true
fi
git add -A
if git rev-parse HEAD >/dev/null 2>&1; then
  git commit -q -m "chore: 更新签到脚本与 workflow" || echo "（无变更需提交）"
else
  git commit -q -m "init: WorkBuddy 云端自动签到"
fi

if "$GH_BIN" repo view "$REPO" >/dev/null 2>&1; then
  echo "ℹ️  仓库已存在：$REPO（只更新内容）"
  git remote get-url origin >/dev/null 2>&1 || "$GH_BIN" repo set-default "$REPO"
  git push -u origin main 2>&1 | tail -3
else
  echo "🚀 创建仓库并推送：$REPO"
  "$GH_BIN" repo create "$REPO" "$VISIBILITY" --source . --remote origin --push 2>&1 | tail -3
fi

# ---- 5. 写 Secrets ----
wb_set WB_CLOUD_REPO "$REPO"
wb_set WB_CLOUD_DIR "$CLOUD_DIR"
echo ""
bash "$WB_ROOT/scripts/push-secret.sh" "$REPO" || exit 1

# ---- 6. 可选：立即验证 ----
if [ "$VERIFY" = "1" ]; then
  echo ""
  echo "▶ 触发一次 workflow 验证…"
  "$GH_BIN" workflow run "checkin.yml" --repo "$REPO" --ref main 2>&1 | tail -2
  sleep 8
  "$GH_BIN" run list --repo "$REPO" --limit 1
  echo "   查看详情：gh run view --repo $REPO --log"
fi

echo ""
echo "✅ 云端部署完成：$REPO"
echo "   后续维护：本机每 10 天自动保鲜 + 回传（阶段 5 配置）"
