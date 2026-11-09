#!/bin/bash
# ============================================================
# WorkBuddy 登录态快照保鲜（token 搬运）
#
# 作用：从桌面端 auth 目录挑选目标账号「最新且服务端有效」的令牌，落地为
#       <repo>/auth/<账号>.info 的**规范化明文快照**，供 checkin.sh / push-secret.sh
#       直接消费（下游三个脚本因此不再依赖桌面端可执行文件）。
#
# 用法：bash scripts/snapshot.sh            # 刷新 config.env 里配置的账号
#       bash scripts/snapshot.sh <uid>      # 只刷新指定 uid
#
# 安全：快照含 accessToken（等同账号密码）。auth/ 已在 .gitignore 中，绝不允许 git add。
#       脚本全程不打印 token 原文。
#
# 选源优先级：
#   1) 桌面端「当前登录态」（workbuddy-desktop.info / workbuddy-desktop-ai.info）
#   2) 历史快照，按 JWT iat 从新到旧
#
# 新鲜度判据为什么是 iat 而不是 expiresAt：
#   WorkBuddy 的 exp = 会话起点 + 固定窗口，滚动刷新只前移 iat、不后延 exp
#   （实测：桌面态 iat 比旧快照新 46.9 小时，exp 反而早 1.1 小时）。
#   用 expiresAt 比较会把「刚刷新的令牌」判为陈旧而拒收。
#
# 历史：
#   v1 按 account.nickname 匹配 -> 5.6+ 昵称被加密，匹配全失败
#   v2 改按明文 account.uid 匹配
#   v3 只接受明文 token，导致桌面当前登录态（加密信封）被整体跳过
#   v4 支持 $wbEncrypted 信封解密（复用 decrypt-token.js + 桌面端原生绑定），
#      当前登录态优先，新鲜度改判 iat，落地为明文快照
# ============================================================
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wb-config.sh"
wb_load

# ---- 目标账号：uid -> 快照文件名 ----
# 多账号：分别配置 WB_ACCOUNT_UID/WB_ACCOUNT_FILE 后各跑一次
if [ -z "${WB_ACCOUNT_UID:-}" ] || [ -z "${WB_ACCOUNT_FILE:-}" ]; then
  echo "config.env 缺少 WB_ACCOUNT_UID / WB_ACCOUNT_FILE"
  echo "请先运行：bash scripts/wb-detect.sh，再按 SKILL.md 阶段 2 写入配置"
  exit 1
fi
declare -A ACCOUNTS=(
  ["$WB_ACCOUNT_UID"]="$WB_ACCOUNT_FILE"
)

ONLY_UID="${1:-}"

# WB_AUTH_DIR 仅供测试覆盖（造故障样本），生产环境用默认路径
AUTH_DIR="${WB_AUTH_DIR:-$(wb_auth_dir)}"
REPO_DIR="${WB_REPO_AUTH_DIR:-$WB_ROOT/auth}"
API="${WB_API:-${WB_API_BASE%/}/v2/billing/meter/checkin-status}"
# 复用同仓库的解密脚本（能处理明文与 $wbEncrypted 信封）
SKILL_JS="${WB_DECRYPT_JS:-$WB_ROOT_M/scripts/decrypt-token.js}"
# 桌面端可执行文件路径缓存（auth/ 已 gitignore，仅本机可见）
APP_EXE_CACHE="$REPO_DIR/.app_exe"

if [ ! -d "$AUTH_DIR" ]; then
  echo "❌ 未找到桌面端 auth 目录: $AUTH_DIR"
  exit 1
fi
if [ ! -f "$SKILL_JS" ]; then
  echo "❌ 未找到 decrypt-token.js: $SKILL_JS（请先安装 workbuddy-checkin skill）"
  exit 1
fi
mkdir -p "$REPO_DIR"

# ---- node 定位（禁止硬编码版本号，运行时升级后仍可用） ----
find_node() {
  local n c
  n="$(command -v node 2>/dev/null)"
  if [ -n "$n" ]; then printf '%s' "$n"; return; fi
  for c in \
    "$HOME/.workbuddy/binaries/node/versions/current/node.exe" \
    "$HOME/.workbuddy-ai/binaries/node/versions/current/node.exe" \
    "$HOME/.workbuddy/binaries/node/versions"/*/node.exe \
    "$HOME/.workbuddy-ai/binaries/node/versions"/*/node.exe; do
    if [ -x "$c" ]; then printf '%s' "$c"; return; fi
  done
  printf ''
}
NODE_BIN="$(find_node)"
if [ -z "$NODE_BIN" ]; then
  echo "❌ 未找到 node，无法解析登录态 JSON"
  exit 1
fi

to_win() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# ---- 桌面端可执行文件定位（信封解密必需） ----
resolve_app_exe() {
  local c root n la pf
  c="${WB_CHECKIN_APP_EXE:-}"
  [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return; }
  c="$(cat "$APP_EXE_CACHE" 2>/dev/null || true)"
  [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return; }
  # 从 <root>/resources/app.asar 反推安装根目录
  c="${WORKBUDDY_APP_PATH:-}"
  if [ -n "$c" ]; then
    c="${c//\\//}"
    root="$(dirname "$(dirname "$c")")"
    for n in WorkBuddyAI.exe WorkBuddy.exe CodeBuddy.exe; do
      [ -f "$root/$n" ] && { printf '%s' "$root/$n"; return; }
    done
  fi
  la="${LOCALAPPDATA:-}"; la="${la//\\//}"
  pf="${ProgramFiles:-}"; pf="${pf//\\//}"
  for root in "$la/Programs/WorkBuddy AI" "$la/Programs/WorkBuddy" "$pf/WorkBuddy AI" "$pf/WorkBuddy"; do
    [ -z "$root" ] && continue
    for n in WorkBuddyAI.exe WorkBuddy.exe; do
      [ -f "$root/$n" ] && { printf '%s' "$root/$n"; return; }
    done
  done
  printf ''
}
APP_EXE="$(resolve_app_exe)"
if [ -n "$APP_EXE" ]; then
  printf '%s' "$APP_EXE" > "$APP_EXE_CACHE" 2>/dev/null || true
  echo "🔑 桌面端: $APP_EXE"
else
  echo "⚠️ 未找到 WorkBuddy 桌面端可执行文件 —— 无法解 \$wbEncrypted 信封，"
  echo "   将退回「仅使用历史明文快照」，无法跟上桌面刷新节奏。"
  echo "   修复：设置 WB_CHECKIN_APP_EXE=<安装目录>/WorkBuddy.exe 后重跑"
fi
echo ""

# ---- 小工具 ----
is_current_login_state() {
  case "$(basename "$1")" in
    workbuddy-desktop.info|workbuddy-desktop-ai.info) return 0 ;;
  esac
  return 1
}

# 从 JWT payload 取字段（iat / exp），失败返回 0
# 注意：node -e 不允许顶层 `return`，必须用 if/else 包裹（否则 SyntaxError → 静默 0）
jwt_field() {
  WB_JWT="$1" WB_FIELD="$2" "$NODE_BIN" -e '
    const t=process.env.WB_JWT||"";
    const p=t.split(".");
    let out="0";
    if(p.length>=2){
      let s=p[1].replace(/-/g,"+").replace(/_/g,"/");
      s+="=".repeat((4-s.length%4)%4);
      try{
        const j=JSON.parse(Buffer.from(s,"base64").toString("utf8"));
        out=String(j[process.env.WB_FIELD]||0);
      }catch(e){ out="0"; }
    }
    process.stdout.write(out);
  ' 2>/dev/null || printf '0'
}

fmt_ts() { [ "${1:-0}" -gt 0 ] 2>/dev/null && date -d @"$1" '+%m-%d %H:%M:%S' 2>/dev/null || echo "未知"; }

# 服务端有效性校验：token 经环境变量传入（不出现在命令行/进程列表）
check_token_ok() {
  WB_CHECK_TOKEN="$1" WB_CHECK_UID="$2" WB_CHECK_DOMAIN="$3" WB_CHECK_API="$API" "$NODE_BIN" -e '
    const ac=new AbortController();const t=setTimeout(()=>ac.abort(),20000);
    fetch(process.env.WB_CHECK_API,{method:"POST",signal:ac.signal,headers:{"Content-Type":"application/json","Accept":"application/json","Authorization":"Bearer "+process.env.WB_CHECK_TOKEN,"X-User-Id":process.env.WB_CHECK_UID,"X-Domain":process.env.WB_CHECK_DOMAIN||""},body:"{}"})
      .then(r=>{clearTimeout(t);process.exit(r.status===200?0:1);})
      .catch(()=>{clearTimeout(t);process.exit(2);});
  ' >/dev/null 2>&1
}

# 从某个登录态文件取「token<TAB>domain」
# 明文直接读；信封则调 decrypt-token.js（需 APP_EXE），并交叉校验 uid 防串号
resolve_token() {
  local path="$1" tt="$2" expect_uid="$3" out tk u d
  if [ "$tt" = "plaintext" ]; then
    WB_F="$path" "$NODE_BIN" -e '
      const fs=require("fs");
      try{const j=JSON.parse(fs.readFileSync(process.env.WB_F,"utf8"));
        const t=j.auth&&j.auth.accessToken;
        process.stdout.write((typeof t==="string"?t:"")+"\t"+((j.auth&&j.auth.domain)||""));}
      catch(e){process.stdout.write("\t");}
    ' 2>/dev/null
    return 0
  fi
  [ -z "$APP_EXE" ] && return 1
  out="$(WB_CHECKIN_AUTH_FILE="$path" WB_CHECKIN_APP_EXE="$APP_EXE" "$NODE_BIN" "$SKILL_JS" 2>/dev/null || true)"
  tk="$(printf '%s' "$out" | grep '^DECRYPT_RESULT:' | cut -d: -f2-)"
  u="$(printf '%s' "$out" | grep '^ACCOUNT_UID:' | cut -d: -f2-)"
  d="$(printf '%s' "$out" | grep '^AUTH_DOMAIN:' | cut -d: -f2-)"
  case "$tk" in ""|ERR*) return 1 ;; esac
  # decrypt-token.js 在显式文件无令牌时会回退默认候选，必须校验 uid 防串号
  if [ -n "$u" ] && [ "$expect_uid" != "$u" ]; then return 1; fi
  printf '%s\t%s' "$tk" "$d"
}

# 写规范化明文快照（下游零依赖）
write_snapshot() {
  WB_OUT="$1" WB_TOKEN="$2" WB_UID="$3" WB_DOMAIN="$4" WB_NICK="$5" \
  WB_EXP="$6" WB_IAT="$7" WB_FROM="$8" WB_KIND="$9" "$NODE_BIN" -e '
    const fs=require("fs");
    const o={
      account:{ uid:process.env.WB_UID||"", nickname:process.env.WB_NICK||"" },
      auth:{
        accessToken:process.env.WB_TOKEN||"",
        domain:process.env.WB_DOMAIN||"",
        expiresAt:Number(process.env.WB_EXP||0)
      },
      _syncedFrom:process.env.WB_FROM||"",
      _syncedKind:process.env.WB_KIND||"",
      _syncedAt:new Date().toISOString(),
      _tokenIat:Number(process.env.WB_IAT||0)
    };
    fs.writeFileSync(process.env.WB_OUT, JSON.stringify(o,null,2)+"\n", "utf8");
  '
}

# ---- 扫描全部登录态文件 ----
RAW="$(find "$AUTH_DIR" -maxdepth 1 -type f \
        \( -name "workbuddy-desktop*.info" -o -name "learnbuddy*.info" \) -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do
          printf '%s\t%s\n' "$(stat -c %Y "$f")" "$(to_win "$f")"
        done)"

if [ -z "$RAW" ]; then
  echo "❌ auth 目录无任何登录态文件，请确认 WorkBuddy 桌面端已登录"
  exit 1
fi

# 解析为：mtime \t tokenType \t uid \t nickname \t expiresAt \t path
PARSED="$(printf '%s\n' "$RAW" | "$NODE_BIN" -e '
  const fs=require("fs");
  const lines=fs.readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);
  for(const ln of lines){
    const i=ln.indexOf("\t"); if(i<0) continue;
    const mt=ln.slice(0,i), p=ln.slice(i+1);
    let tt="unreadable",uid="",nick="",exp="0";
    try{
      const j=JSON.parse(fs.readFileSync(p,"utf8"));
      const t=j.auth&&j.auth.accessToken;
      tt=typeof t==="string"?"plaintext":(t&&t.$wbEncrypted?"encrypted":"none");
      uid=String((j.account&&j.account.uid)||"");
      const n=j.account&&j.account.nickname;
      nick=typeof n==="string"?n:"";
      exp=String((j.auth&&j.auth.expiresAt)||0);
    }catch(e){}
    process.stdout.write([mt,tt,uid,nick,exp,p].join("\x1f")+"\n");
  }
')"

if [ -z "$PARSED" ]; then
  echo "❌ auth 目录无任何可解析的登录态文件"
  exit 1
fi

echo "📋 扫描到 $(printf '%s\n' "$PARSED" | wc -l | tr -d ' ') 个登录态文件"
echo ""

# token 解析缓存（避免同一文件被解密两次，信封解密需启动 200MB 的桌面端进程）
declare -A TOKCACHE

OK_COUNT=0
TOTAL=0
for uid in "${!ACCOUNTS[@]}"; do
  if [ -n "$ONLY_UID" ] && [ "$ONLY_UID" != "$uid" ]; then continue; fi
  TOTAL=$((TOTAL + 1))
  TARGET_FILE="${ACCOUNTS[$uid]}"
  TARGET_PATH="$REPO_DIR/$TARGET_FILE"
  echo "── 账号 ${uid} → auth/${TARGET_FILE}"

  # 收集候选：优先级(0=当前登录态) | iat | mtime | 路径 | 类型 | 说明 | expiresAt | nickname
  # 分隔符用 \x1f（US）而非 tab：tab 属 IFS 空白字符，read 会把连续分隔符折叠，
  # 导致「昵称为空」的行整体错位、路径丢失（v4 初版实测踩坑）。
  LIST=""
  while IFS=$'\x1f' read -r mt tt cu nick exp path; do
    [ -z "${path:-}" ] && continue
    [ "$cu" = "$uid" ] || continue
    if [ -n "${TOKCACHE[$path]:-}" ]; then
      RES="${TOKCACHE[$path]}"
    else
      RES="$(resolve_token "$path" "$tt" "$uid")" || RES=""
      TOKCACHE[$path]="$RES"
    fi
    TOK="${RES%%$'\t'*}"
    if [ -z "$TOK" ]; then
      if [ "$tt" = "encrypted" ]; then
        echo "   ↷ 跳过 $(basename "$path")（\$wbEncrypted 信封解密失败）"
      elif [ "$tt" != "plaintext" ]; then
        echo "   ↷ 跳过 $(basename "$path")（无 accessToken）"
      fi
      continue
    fi
    IAT="$(jwt_field "$TOK" iat)"
    if is_current_login_state "$path"; then PRIO=0; KIND="桌面当前登录态"; else PRIO=1; KIND="历史快照"; fi
    LIST="${LIST}${PRIO}"$'\x1f'"${IAT}"$'\x1f'"${mt}"$'\x1f'"${path}"$'\x1f'"${tt}"$'\x1f'"${KIND}"$'\x1f'"${exp}"$'\x1f'"${nick}"$'\n'
  done <<< "$PARSED"

  if [ -z "$LIST" ]; then
    echo "   ⚠️ 无可用候选（该账号当前未登录且无历史明文快照），保留现有 ${TARGET_FILE}"
    echo ""
    continue
  fi

  SORTED="$(printf '%s' "$LIST" | sort -t$'\x1f' -k1,1n -k2,2rn -k3,3rn)"
  echo "   📋 候选（优先级从高到低）："
  printf '%s' "$SORTED" | while IFS=$'\x1f' read -r p i m pa t k e n; do
    [ -z "${pa:-}" ] && continue
    echo "      [$k] iat=$(fmt_ts "${i:-0}")  $(basename "$pa")"
  done

  # 现有快照的 iat 与 token（作为覆盖门槛）
  CUR_IAT=0
  CUR_TOK=""
  if [ -f "$TARGET_PATH" ]; then
    CTT="$("$NODE_BIN" -e '
      const fs=require("fs");
      try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        const t=j.auth&&j.auth.accessToken;
        process.stdout.write(typeof t==="string"?"plaintext":(t&&t.$wbEncrypted?"encrypted":"none"));}
      catch(e){process.stdout.write("none");}
    ' "$(to_win "$TARGET_PATH")" 2>/dev/null || echo none)"
    if [ -n "${TOKCACHE[$(to_win "$TARGET_PATH")]:-}" ]; then
      CRES="${TOKCACHE[$(to_win "$TARGET_PATH")]}"
    else
      CRES="$(resolve_token "$(to_win "$TARGET_PATH")" "$CTT" "$uid")" || CRES=""
      TOKCACHE[$(to_win "$TARGET_PATH")]="$CRES"
    fi
    CUR_TOK="${CRES%%$'\t'*}"
    if [ -n "$CUR_TOK" ]; then CUR_IAT="$(jwt_field "$CUR_TOK" iat)"; fi
    echo "   ℹ️ 现有快照 iat=$(fmt_ts "$CUR_IAT")"
  else
    echo "   ℹ️ 现有快照不存在（首次落地）"
  fi

  WIN_PATH=""; WIN_TOK=""; WIN_IAT=0; WIN_DOM=""; WIN_EXP="0"; WIN_NICK=""; WIN_KIND=""
  while IFS=$'\x1f' read -r p i m pa t k e n; do
    [ -z "${pa:-}" ] && continue
    RES="${TOKCACHE[$pa]:-}"
    TOK="${RES%%$'\t'*}"
    DOM="${RES#*$'\t'}"
    [ "$DOM" = "$RES" ] && DOM=""
    [ -z "$TOK" ] && continue

    check_token_ok "$TOK" "$uid" "$DOM"
    case "$?" in
      0) : ;;
      1)
        echo "   ↷ $(basename "$pa") 服务端校验未通过（HTTP 非 200，令牌可能已作废）"
        continue
        ;;
      *)
        # 网络异常 ≠ 令牌失效：绝不能当成「不优于现有快照」而静默保留旧令牌
        echo "   ❌ 网络异常，无法校验令牌有效性，中止（不覆盖现有快照）"
        exit 2
        ;;
    esac
    if [ -n "$CUR_TOK" ] && [ "$TOK" = "$CUR_TOK" ]; then
      echo "   ↷ $(basename "$pa") 与现有快照为同一枚令牌，无需覆盖"
      break
    fi
    if [ "$p" = "0" ]; then
      echo "   ✅ 采用 $k（$(basename "$pa")）：权威来源，直接覆盖"
      WIN_PATH="$pa"; WIN_TOK="$TOK"; WIN_IAT="${i:-0}"; WIN_DOM="$DOM"; WIN_EXP="${e:-0}"; WIN_NICK="${n:-}"; WIN_KIND="$k"
      break
    fi
    if [ "${i:-0}" -gt "${CUR_IAT:-0}" ]; then
      echo "   ✅ 采用 $k（$(basename "$pa")）：iat 更新 $(( ${i:-0} - ${CUR_IAT:-0} ))s"
      WIN_PATH="$pa"; WIN_TOK="$TOK"; WIN_IAT="${i:-0}"; WIN_DOM="$DOM"; WIN_EXP="${e:-0}"; WIN_NICK="${n:-}"; WIN_KIND="$k"
      break
    fi
    echo "   ↷ $(basename "$pa") 不比现有快照新（iat ${i:-0} ≤ ${CUR_IAT:-0}），跳过"
  done <<< "$SORTED"

  if [ -n "$WIN_PATH" ]; then
    # 昵称在加密登录态里读不到，回退取 JWT 的 nickname 声明（仅为可读性，不参与判定）
    if [ -z "$WIN_NICK" ]; then
      WIN_NICK="$(jwt_field "$WIN_TOK" nickname)"
      [ "$WIN_NICK" = "0" ] && WIN_NICK=""
    fi
    if write_snapshot "$TARGET_PATH" "$WIN_TOK" "$uid" "$WIN_DOM" "$WIN_NICK" "$WIN_EXP" "$WIN_IAT" "$WIN_PATH" "$WIN_KIND"; then
      LEFT="$(WB_JWT="$WIN_TOK" "$NODE_BIN" -e '
        const t=process.env.WB_JWT||"";const p=t.split(".");
        if(p.length<2){console.log("?");process.exit(0);}
        let s=p[1].replace(/-/g,"+").replace(/_/g,"/");s+="=".repeat((4-s.length%4)%4);
        try{const j=JSON.parse(Buffer.from(s,"base64").toString("utf8"));
          console.log(((j.exp*1000-Date.now())/86400000).toFixed(1));}catch(e){console.log("?");}
      ' 2>/dev/null || echo "?")"
      echo "✅ [$uid] 快照已更新 → auth/$TARGET_FILE"
      echo "   来源: $WIN_KIND（$(basename "$WIN_PATH")）"
      echo "   iat: $(fmt_ts "$WIN_IAT") | token 剩余: ${LEFT} 天"
      OK_COUNT=$((OK_COUNT + 1))
    else
      echo "❌ [$uid] 快照写入失败"
    fi
  else
    echo "⚠️ [$uid] 无需更新（保留现有 $TARGET_FILE）"
  fi
  echo ""
done

echo "✅ 快照同步完成：成功更新 $OK_COUNT/$TOTAL 个账号"
[ "$OK_COUNT" -gt 0 ] || exit 0
exit 0
