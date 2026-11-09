#!/bin/bash
# ============================================================
# 环境体检（只读，不修改任何文件）
#
# 作用：把「这台机器现在能不能签到」一次性问清楚，输出人类可读报告 +
#       DETECT:KEY=VALUE 机器可读行，供 Agent 决策下一步。
#
# 用法：bash scripts/wb-detect.sh [--no-net]
#   --no-net  跳过网络探测（离线环境 / 不想触网时用）
#
# 退出码：0 = 可直接签到；1 = 有告警但可尝试；2 = 存在硬阻塞
# ============================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wb-config.sh"
wb_load

NO_NET=0
[ "${1:-}" = "--no-net" ] && NO_NET=1

BLOCK=0
WARN=0
emit() { printf 'DETECT:%s=%s\n' "$1" "$2"; }
block() { BLOCK=$((BLOCK + 1)); echo "  [阻塞] $*"; }
warn() { WARN=$((WARN + 1)); echo "  [告警] $*"; }
ok() { echo "  [通过] $*"; }

echo "════════ 1. 平台与运行时 ════════"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PLAT="windows" ;;
  Darwin) PLAT="macos" ;;
  Linux) PLAT="linux" ;;
  *) PLAT="unknown" ;;
esac
emit PLATFORM "$PLAT"
echo "  平台: $PLAT ($(uname -s))"
echo "  仓库: $WB_ROOT_M"

NODE_BIN="$(wb_find_node)"
if [ -n "$NODE_BIN" ]; then
  NODE_VER="$("$NODE_BIN" -v 2>&1)"
  ok "Node: $NODE_BIN ($NODE_VER)"
  emit NODE "$(wb_native_path "$NODE_BIN")"
  emit NODE_VERSION "$NODE_VER"
else
  block "未找到 Node.js —— 无法读取登录态 JSON。请安装 Node.js 20+ 或设置 WB_NODE_BIN"
  emit NODE ""
fi

PY_BIN="$(wb_find_python)"
if [ -n "$PY_BIN" ]; then
  ok "Python: $(wb_native_path "$PY_BIN")"
  emit PYTHON "$(wb_native_path "$PY_BIN")"
else
  warn "未找到 python/python3 —— 签到结果详情会降级为 unknown（签到本身仍会执行）"
  emit PYTHON ""
fi

GH_BIN="$(wb_find_gh)"
if [ -n "$GH_BIN" ]; then
  if GH_OK="$("$GH_BIN" auth status 2>&1)" && printf '%s' "$GH_OK" | grep -q "Logged in"; then
    GH_USER="$("$GH_BIN" api user --jq .login 2>/dev/null)"
    ok "gh CLI 已登录: ${GH_USER:-unknown}"
    emit GH "$(wb_native_path "$GH_BIN")"
    emit GH_USER "${GH_USER:-}"
  else
    warn "gh CLI 已安装但未登录 —— 云端部署前需执行 gh auth login"
    emit GH "$(wb_native_path "$GH_BIN")"
    emit GH_USER ""
  fi
else
  warn "未找到 gh CLI —— 只能做本地签到，无法自动配置云端任务"
  emit GH ""
  emit GH_USER ""
fi

echo ""
echo "════════ 2. WorkBuddy 桌面端登录态 ════════"
case "$PLAT" in
  windows) AUTH_DIR="${LOCALAPPDATA:-$HOME/AppData/Local}/CodeBuddyExtension/Data/Public/auth" ;;
  macos)   AUTH_DIR="$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth" ;;
  *)       AUTH_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/CodeBuddyExtension/Data/Public/auth" ;;
esac
emit AUTH_DIR "$AUTH_DIR"

if [ ! -d "$AUTH_DIR" ]; then
  block "未找到登录态目录：$AUTH_DIR
         请先安装 WorkBuddy 桌面端并**登录一次**，再重跑本脚本"
  emit AUTH_FILES 0
else
  CNT="$(find "$AUTH_DIR" -maxdepth 1 -type f -name "*.info" 2>/dev/null | wc -l | tr -d ' ')"
  ok "登录态目录存在，含 $CNT 个 .info 文件"
  emit AUTH_FILES "$CNT"

  # 用 node 汇总每个文件的 uid / 令牌类型（不解密，快）
  SUMMARY="$("$NODE_BIN" -e '
    const fs=require("fs"),path=require("path");
    const dir=process.argv[1];
    let files=[];
    try{files=fs.readdirSync(dir).filter(f=>f.endsWith(".info"));}catch(e){}
    for(const f of files){
      const p=path.join(dir,f);let uid="",tt="unreadable",nick="",exp=0,mt=0;
      try{mt=fs.statSync(p).mtimeMs;}catch(e){}
      try{
        const j=JSON.parse(fs.readFileSync(p,"utf8"));
        const t=j.auth&&j.auth.accessToken;
        tt=typeof t==="string"?"plaintext":(t&&t.$wbEncrypted?"encrypted":"none");
        uid=String((j.account&&j.account.uid)||"");
        const n=j.account&&j.account.nickname;
        nick=typeof n==="string"?n:"";
        exp=Number((j.auth&&j.auth.expiresAt)||0);
      }catch(e){}
      console.log([f,tt,uid,nick,exp,mt].join("\x1f"));
    }
  ' "$(wb_native_path "$AUTH_DIR")" 2>/dev/null)"

  if [ -z "$SUMMARY" ]; then
    block "登录态目录里没有可解析的 .info 文件"
  else
    echo "  文件名                                    类型         uid"
    printf '%s\n' "$SUMMARY" | while IFS=$'\x1f' read -r f tt uid nick exp mt; do
      [ -z "$f" ] && continue
      printf '  %-40s %-11s %s\n' "$f" "$tt" "${uid:0:8}..."
    done
    # 候选「当前登录态」有两个：workbuddy-desktop.info 与 workbuddy-desktop-ai.info。
    # 它们**可能属于不同账号**（桌面端多客户端并存时），随便挑一个就会签错号。
    # 规则：优先精确的 workbuddy-desktop.info；若两者 uid 不同则标记歧义，交由用户选择。
    CUR_LINES="$(printf '%s\n' "$SUMMARY" | grep -E '^workbuddy-desktop(-ai)?\.info')"
    UIDS_ALL="$(printf '%s\n' "$SUMMARY" | awk -F$'\x1f' 'NF>2 && $3!="" {print $3}' | sort -u | tr '\n' ',' | sed 's/,$//')"
    N_UIDS="$(printf '%s\n' "$UIDS_ALL" | tr ',' '\n' | grep -c . || echo 0)"
    emit UIDS_ALL "$UIDS_ALL"

    if [ -z "$CUR_LINES" ]; then
      CUR_LINE="$(printf '%s\n' "$SUMMARY" | head -1)"
    else
      CUR_LINE="$(printf '%s\n' "$CUR_LINES" | grep -E '^workbuddy-desktop\.info' | head -1)"
      if [ -z "$CUR_LINE" ]; then
        CUR_LINE="$(printf '%s\n' "$CUR_LINES" | head -1)"
      fi
      # 歧义检测：多个「当前登录态」指向不同 uid
      CUR_UIDS="$(printf '%s\n' "$CUR_LINES" | awk -F$'\x1f' '{print $3}' | sort -u | grep -c . || echo 0)"
      if [ "${CUR_UIDS:-0}" -gt 1 ]; then
        warn "存在多个「当前登录态」且分属不同账号 —— 必须显式指定用哪个（见 UIDS_ALL）"
        printf '%s\n' "$CUR_LINES" | awk -F$'\x1f' '{printf "         %-32s %s\n", $1, $3}'
        emit AMBIGUOUS "yes"
      else
        emit AMBIGUOUS "no"
      fi
    fi
    CUR_FILE="$(printf '%s' "$CUR_LINE" | cut -d$'\x1f' -f1)"
    CUR_TYPE="$(printf '%s' "$CUR_LINE" | cut -d$'\x1f' -f2)"
    CUR_UID="$(printf '%s' "$CUR_LINE" | cut -d$'\x1f' -f3)"
    ok "当前登录态: $CUR_FILE（$CUR_TYPE）"
    emit CURRENT_AUTH_FILE "$CUR_FILE"
    emit CURRENT_TOKEN_TYPE "$CUR_TYPE"
    emit CURRENT_UID "$CUR_UID"

    if [ "$CUR_TYPE" = "encrypted" ]; then
      echo "  提示: 令牌为 \$wbEncrypted 信封（WorkBuddy 5.6+ 字段级加密），"
      echo "        解密需桌面端可执行文件，请确认下方 APP_EXE 已定位。"
    fi
  fi
fi

echo ""
echo "════════ 3. 桌面端可执行文件（信封解密前置） ════════"
APP_EXE="${WB_APP_EXE:-}"
if [ -z "$APP_EXE" ] && [ -f "$WB_ROOT/auth/.app_exe" ]; then
  APP_EXE="$(cat "$WB_ROOT/auth/.app_exe" 2>/dev/null)"
fi
if [ -z "$APP_EXE" ]; then
  # 顺序：WORKBUDDY_APP_PATH 反推 → 标准安装位置 → 盘符根目录下 *workbuddy* 目录
  # 最后一条是为「用户把客户端装在 D:\ 或 G:\ 自定义目录」准备的，否则信封永远解不开。
  AP="${WORKBUDDY_APP_PATH:-}"
  if [ -n "$AP" ]; then
    AP="${AP//\\//}"
    ROOT_CAND="$(dirname "$(dirname "$AP")")"
    for n in WorkBuddyAI.exe WorkBuddy.exe; do
      [ -f "$ROOT_CAND/$n" ] && { APP_EXE="$ROOT_CAND/$n"; break; }
    done
  fi
fi
if [ -z "$APP_EXE" ]; then
  if [ "$PLAT" = "windows" ]; then
    LA="${LOCALAPPDATA:-}"; PF="${ProgramFiles:-C:/Program Files}"
    for c in "$LA/Programs/WorkBuddy AI/WorkBuddyAI.exe" "$LA/Programs/WorkBuddy AI/WorkBuddy.exe" \
             "$LA/Programs/WorkBuddy/WorkBuddy.exe" "$PF/WorkBuddy AI/WorkBuddyAI.exe" \
             "$PF/WorkBuddy/WorkBuddy.exe"; do
      [ -f "$c" ] && { APP_EXE="$c"; break; }
    done
    if [ -z "$APP_EXE" ]; then
      for d in /c /d /e /f /g /h; do
        for c in "$d"/*workbuddy*/WorkBuddy.exe "$d"/*workbuddy*/WorkBuddyAI.exe \
                 "$d"/*WorkBuddy*/WorkBuddy.exe "$d"/*CodeBuddy*/CodeBuddy.exe; do
          [ -f "$c" ] && { APP_EXE="$c"; break 2; }
        done
      done
    fi
  elif [ "$PLAT" = "macos" ]; then
    for c in "/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy" \
             "/Applications/WorkBuddy AI.app/Contents/MacOS/WorkBuddy AI" \
             "$HOME/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy"; do
      [ -f "$c" ] && { APP_EXE="$c"; break; }
    done
  fi
fi
if [ -n "$APP_EXE" ] && [ -f "$APP_EXE" ]; then
  ok "已定位: $APP_EXE"
  emit APP_EXE "$APP_EXE"
else
  if [ "${CUR_TYPE:-}" = "encrypted" ]; then
    block "登录态是加密信封，但未找到 WorkBuddy 桌面端可执行文件。
           请设 WB_APP_EXE=<安装目录>/WorkBuddy.exe（写进 config.env）后重跑"
  else
    warn "未定位桌面端可执行文件（当前令牌为明文，暂不影响）"
  fi
  emit APP_EXE ""
fi

echo ""
echo "════════ 4. 令牌可用性（服务端实测） ════════"
if [ -z "${NODE_BIN:-}" ] || [ -z "${CUR_FILE:-}" ]; then
  warn "跳过（缺少 Node 或登录态）"
else
  OUT="$(WB_CHECKIN_AUTH_FILE="$(wb_native_path "$AUTH_DIR")/$CUR_FILE" \
         WB_CHECKIN_APP_EXE="${APP_EXE:-}" "$NODE_BIN" "$WB_ROOT_M/scripts/decrypt-token.js" 2>&1)"
  TOKEN="$(printf '%s' "$OUT" | grep '^DECRYPT_RESULT:' | sed 's/^DECRYPT_RESULT://')"
  UID_VAL="$(printf '%s' "$OUT" | grep '^ACCOUNT_UID:' | sed 's/^ACCOUNT_UID://')"
  DOM_VAL="$(printf '%s' "$OUT" | grep '^AUTH_DOMAIN:' | sed 's/^AUTH_DOMAIN://')"
  if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
    block "读取令牌失败：${TOKEN#ERR }"
    emit TOKEN_STATE "unreadable"
  else
    LEFT="$(wb_days_left "$TOKEN")"
    IAT="$(wb_jwt_field "$TOKEN" iat)"
    ok "令牌已读取（uid=${UID_VAL:0:8}...，剩余 ${LEFT} 天）"
    echo "  提示：剩余天数只是参考。滚动续签时 exp 可能不变，重建会话时 exp 会前移，"
    echo "        两种都实测到过；判有效性只认服务端 HTTP 状态码。"
    emit TOKEN_UID "$UID_VAL"
    emit TOKEN_DOMAIN "$DOM_VAL"
    emit TOKEN_IAT "$IAT"
    emit TOKEN_DAYS_LEFT "$LEFT"
    # 昵称在加密登录态里读不到，回退取 JWT 的 nickname 声明（仅为可读性，不参与判定）
    JNICK="$(wb_jwt_field "$TOKEN" nickname)"
    [ "$JNICK" = "0" ] && JNICK=""
    emit TOKEN_NICKNAME "$JNICK"

    if [ "$NO_NET" = "0" ]; then
      CODE="$(WB_T="$TOKEN" WB_U="$UID_VAL" WB_D="$DOM_VAL" WB_API="$WB_API_BASE/v2/billing/meter/checkin-status" "$NODE_BIN" -e '
        const ac=new AbortController();const t=setTimeout(()=>ac.abort(),20000);
        fetch(process.env.WB_API,{method:"POST",signal:ac.signal,headers:{"Content-Type":"application/json","Accept":"application/json","Authorization":"Bearer "+process.env.WB_T,"X-User-Id":process.env.WB_U,"X-Domain":process.env.WB_D||""},body:"{}"})
          .then(r=>{clearTimeout(t);process.stdout.write(String(r.status));process.exit(0);})
          .catch(()=>{clearTimeout(t);process.stdout.write("0");process.exit(0);});
      ' 2>/dev/null)"
      case "$CODE" in
        200) ok "服务端校验 HTTP 200 —— 令牌可用"; emit TOKEN_STATE "valid" ;;
        401|403) block "服务端返回 HTTP $CODE —— 令牌已失效，请在桌面端重新登录"; emit TOKEN_STATE "expired" ;;
        0) warn "网络不可达，无法校验（这不代表令牌失效）"; emit TOKEN_STATE "unknown" ;;
        *) warn "服务端返回 HTTP $CODE，非预期状态码"; emit TOKEN_STATE "http_$CODE" ;;
      esac
    else
      emit TOKEN_STATE "skipped"
    fi
  fi
fi

echo ""
echo "════════ 5. 本机配置与云端状态 ════════"
if [ -f "$WB_CONFIG" ]; then
  ok "config.env 已存在"
  echo "  账号名    : $(wb_get WB_ACCOUNT_NAME '（未设置）')"
  echo "  账号 uid  : $(wb_get WB_ACCOUNT_UID '（未设置）')"
  echo "  云端仓库  : $(wb_get WB_CLOUD_REPO '（未设置）')"
  echo "  云端目录  : $WB_CLOUD_DIR"
  emit CONFIGURED "yes"
else
  warn "config.env 不存在（首次部署属正常，阶段 2 会生成）"
  emit CONFIGURED "no"
fi

if [ -n "${GH_BIN:-}" ] && [ -n "$(wb_get WB_CLOUD_REPO)" ]; then
  RUNS="$("$GH_BIN" run list --repo "$(wb_get WB_CLOUD_REPO)" --limit 3 2>&1)"
  if printf '%s' "$RUNS" | grep -qE "completed|in_progress|queued"; then
    ok "云端 workflow 近 3 次运行："
    printf '%s\n' "$RUNS" | sed 's/^/    /'
  else
    warn "无法读取云端运行记录（仓库不存在 / 无权限 / workflow 未创建）"
  fi
fi

echo ""
echo "════════ 结论 ════════"
emit BLOCKERS "$BLOCK"
emit WARNINGS "$WARN"
if [ "$BLOCK" -gt 0 ]; then
  echo "❌ 存在 $BLOCK 个硬阻塞，需先处理（见上方 [阻塞] 项）"
  exit 2
elif [ "$WARN" -gt 0 ]; then
  echo "⚠️  体检通过，但有 $WARN 个告警；可以继续，功能可能受限"
  exit 1
else
  echo "✅ 体检全部通过，可以开始签到"
  exit 0
fi
