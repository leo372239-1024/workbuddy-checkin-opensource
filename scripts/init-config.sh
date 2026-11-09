#!/bin/bash
# ============================================================
# 生成本机配置 config.env（阶段 2）
#
# 设计要点：**账号必须显式确定，不许猜。**
# 桌面端可能同时存在多份「当前登录态」（workbuddy-desktop.info 与
# workbuddy-desktop-ai.info），它们可能属于不同账号。自动挑一个的代价是
# 「签到一直成功，但积分进的是另一个号」——这类错误极难察觉。
# 所以：只有一个 uid 时才自动选；出现多个一律停下要用户指定。
#
# 用法：
#   bash scripts/init-config.sh                 # 单账号机器：直接写
#   bash scripts/init-config.sh --uid <uid>     # 多账号机器：指定用哪个
#   bash scripts/init-config.sh --force         # 覆盖已有值
# ============================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wb-config.sh"
wb_load

FORCE=0
UID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --uid) UID_ARG="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "▶ 环境体检（不触网）…"
DETECT_OUT="$(bash "$WB_ROOT/scripts/wb-detect.sh" --no-net 2>&1)"
printf '%s\n' "$DETECT_OUT" | grep -v '^DETECT:' | sed 's/^/  /'
get() { printf '%s\n' "$DETECT_OUT" | grep "^DETECT:$1=" | head -1 | cut -d= -f2-; }

BLOCK="$(get BLOCKERS)"
if [ "${BLOCK:-0}" -gt 0 ] && [ "$(get AMBIGUOUS)" != "yes" ]; then
  echo ""
  echo "❌ 体检存在硬阻塞，先解决再写配置（见上方 [阻塞] 项）"
  exit 2
fi

AUTH_DIR="$(get AUTH_DIR)"
NODE_BIN="$(wb_find_node)"
[ -n "$NODE_BIN" ] || { echo "❌ 未找到 node"; exit 2; }

# ---- 扫出所有 (文件, 类型, uid, 昵称)，按 uid 分组 ----
TABLE="$("$NODE_BIN" -e '
  const fs=require("fs"),path=require("path");
  const dir=process.argv[1];
  let files=[];
  try{files=fs.readdirSync(dir).filter(f=>f.endsWith(".info"));}catch(e){}
  const out=[];
  for(const f of files){
    const p=path.join(dir,f);let uid="",tt="none",nick="",mt=0;
    try{mt=fs.statSync(p).mtimeMs;}catch(e){}
    try{
      const j=JSON.parse(fs.readFileSync(p,"utf8"));
      const t=j.auth&&j.auth.accessToken;
      tt=typeof t==="string"?"plaintext":(t&&t.$wbEncrypted?"encrypted":"none");
      uid=String((j.account&&j.account.uid)||"");
      const n=j.account&&j.account.nickname;
      nick=typeof n==="string"?n:"";
    }catch(e){}
    if(uid) out.push([f,tt,uid,nick,mt].join("\x1f"));
  }
  process.stdout.write(out.join("\n"));
' "$(wb_native_path "$AUTH_DIR")" 2>/dev/null)"

[ -z "$TABLE" ] && { echo "❌ 登录态目录里没有带 uid 的文件"; exit 2; }

UIDS="$(printf '%s\n' "$TABLE" | awk -F$'\x1f' '{print $3}' | sort -u)"
N_UIDS="$(printf '%s\n' "$UIDS" | grep -c . || echo 0)"

if [ -n "$UID_ARG" ]; then
  CHOSEN="$UID_ARG"
elif [ "$N_UIDS" -eq 1 ]; then
  CHOSEN="$UIDS"
else
  echo ""
  echo "⚠️  本机存在 $N_UIDS 个不同账号，无法自动决定给哪个账号签到："
  echo ""
  # 按 uid 去重，只展示每个账号最合适的那份登录态（当前登录态优先、其次最新）
  "$NODE_BIN" -e '
    const fs=require("fs");
    const lines=fs.readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);
    const rows=lines.map(l=>{const p=l.split("\x1f");
      return {f:p[0],tt:p[1],u:p[2],nick:p[3]||"",mt:Number(p[4])||0};});
    const byUid=new Map();
    for(const r of rows){
      const cur=byUid.get(r.u);
      const pri=x=>/^workbuddy-desktop(-ai)?\.info$/.test(x.f)?0:1;
      if(!cur || pri(r)<pri(cur) || (pri(r)===pri(cur) && r.mt>cur.mt)) byUid.set(r.u,r);
    }
    let i=0;
    for(const [uid,r] of byUid){
      i++;
      const nick=r.nick||"(昵称加密读不到)";
      console.log(`  ${i}. uid=${uid}   昵称=${nick}   优先源=${r.f} (${r.tt})`);
    }
  ' <<< "$TABLE"
  echo ""
  echo "请用上面某个完整 uid 重新执行，例如："
  echo "  bash scripts/init-config.sh --uid <完整 uid>"
  echo "（选错账号 = 积分进错号，所以这里不做自动选择）"
  exit 2
fi

# 该 uid 下挑「当前登录态」优先，其次 mtime 最新
# 用 node 做选择：awk 的 \x1f 转义在 gawk/mawk 上行为不一致，不值得赌
LINE="$("$NODE_BIN" -e '
  const fs=require("fs");
  const lines=fs.readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);
  const uid=process.argv[1];
  const rows=lines.map(l=>{
    const p=l.split("\x1f");
    return {f:p[0],tt:p[1],u:p[2],nick:p[3]||"",mt:Number(p[4])||0};
  }).filter(r=>r.u===uid);
  if(!rows.length) process.exit(1);
  const pri=r=>/^workbuddy-desktop(-ai)?\.info$/.test(r.f)?0:1;
  rows.sort((a,b)=> pri(a)-pri(b) || b.mt-a.mt);
  const w=rows[0];
  process.stdout.write([w.f,w.tt,w.u,w.nick].join("\x1f"));
' "$CHOSEN" <<< "$TABLE")"
[ -z "$LINE" ] && { echo "❌ uid=$CHOSEN 没有对应的登录态文件"; exit 2; }

CUR_FILE="$(printf '%s' "$LINE" | cut -d$'\x1f' -f1)"
CUR_TYPE="$(printf '%s' "$LINE" | cut -d$'\x1f' -f2)"
NICK="$(printf '%s' "$LINE" | cut -d$'\x1f' -f4)"
# 昵称常被加密读不到，回退 JWT 的 nickname 声明，再回退 uid 前缀
if [ -z "$NICK" ]; then
  NICK="$(get TOKEN_NICKNAME)"
fi
[ -z "$NICK" ] && NICK="${CHOSEN:0:8}"
SLUG="$(wb_slug "$NICK")"
[ -z "$SLUG" ] && SLUG="${CHOSEN:0:8}"

APP_EXE="$(get APP_EXE)"
API_BASE="${WB_API_BASE_DEFAULT}"
# 客户端装在非标准目录（如 D:\Apps\WorkBuddy）时探测不到，需要用户显式指定
if [ -z "$APP_EXE" ] && [ "$CUR_TYPE" = "encrypted" ]; then
  echo ""
  echo "❌ 该账号令牌是 \$wbEncrypted 信封，但没探测到桌面端可执行文件。"
  echo "   请先设置后再重跑："
  echo "     bash scripts/init-config.sh --uid $CHOSEN    # 然后手工在 config.env 补一行"
  echo "     WB_APP_EXE=C:/path/to/WorkBuddy.exe"
  exit 2
fi

echo ""
echo "选定账号：$NICK（uid=${CHOSEN:0:8}…，源文件 $CUR_FILE，类型 $CUR_TYPE）"
echo "将写入 $WB_CONFIG："
echo "  WB_ACCOUNT_NAME = $NICK"
echo "  WB_ACCOUNT_UID  = $CHOSEN"
echo "  WB_ACCOUNT_FILE = $SLUG.info"
echo "  WB_APP_EXE      = ${APP_EXE:-（空，明文令牌无需）}"

set_or_keep() {
  local k="$1" v="$2"
  # 「已存在」以配置文件里有没有这行为准，而不是 wb_get 的有效值
  # （默认值会让 wb_get 永远非空，导致该写的键被永久跳过）
  if grep -q "^${k}=" "$WB_CONFIG" 2>/dev/null && [ "$FORCE" = "0" ]; then
    echo "  ↷ $k 已在配置中，保留"
  else
    wb_set "$k" "$v"
    echo "  ＋ $k = $v"
  fi
}
set_or_keep WB_ACCOUNT_NAME "$NICK"
set_or_keep WB_ACCOUNT_UID  "$CHOSEN"
set_or_keep WB_ACCOUNT_FILE "$SLUG.info"
set_or_keep WB_API_BASE     "$API_BASE"
[ -n "$APP_EXE" ] && set_or_keep WB_APP_EXE "$APP_EXE"
grep -q '^WB_SECRET_SUFFIX=' "$WB_CONFIG" 2>/dev/null || wb_set WB_SECRET_SUFFIX ""

echo ""
echo "✅ 配置已写入（该文件已 .gitignore，不会被提交）"
echo "   下一步：bash scripts/checkin.sh"
