#!/bin/bash
# ============================================================
# 配置读写库（被其他脚本 source，不单独执行）
#
# 设计原则：所有「跟具体机器/账号绑定」的值只存在一个地方 —— <repo>/config.env。
# 该文件已写入 .gitignore，任何脚本都不得把值硬编码回代码。
#
# 用法：
#   source "$(dirname "$0")/wb-config.sh"
#   wb_load                      # 载入 config.env（不存在则用默认值）
#   wb_get WB_ACCOUNT_UID        # 取单个值（未设置时为空串）
#   wb_set WB_ACCOUNT_UID abc    # 写入/更新（自动创建文件）
# ============================================================

# 仓库根目录（本文件所在目录的上一级）
WB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cygpath >/dev/null 2>&1 && WB_ROOT_M="$(cygpath -m "$WB_ROOT")" || WB_ROOT_M="$WB_ROOT"
WB_CONFIG="$WB_ROOT/config.env"

# 默认值
WB_API_BASE_DEFAULT="https://copilot.tencent.com"
WB_CLOUD_DIR_DEFAULT="$WB_ROOT/cloud"

# 载入配置（config.env 是纯 KEY=VALUE，可直接 source）
wb_load() {
  # shellcheck disable=SC1090
  [ -f "$WB_CONFIG" ] && . "$WB_CONFIG"
  WB_API_BASE="${WB_API_BASE:-$WB_API_BASE_DEFAULT}"
  WB_CLOUD_DIR="${WB_CLOUD_DIR:-$WB_CLOUD_DIR_DEFAULT}"
  return 0
}

wb_get() {
  local k="$1" d="${2:-}"
  local v="${!k:-}"
  printf '%s' "${v:-$d}"
}

# 写入配置项：存在则替换整行，不存在则追加。
# 刻意不用 sed -i：Windows 路径里的反斜杠会被 sed 替换串吃掉
# （C:\Program Files 会变成 C:Program Files），这类静默损坏极难发现。
wb_set() {
  local k="$1" v="$2" tmp line
  [ -f "$WB_CONFIG" ] || printf '# WorkBuddy 签到本机配置（已 gitignore，勿提交）\n' > "$WB_CONFIG"
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$k="*) ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$WB_CONFIG"
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$WB_CONFIG"
}

# 账号名归一化：去掉不能进文件名/任务名的字符，保留字母数字与常见分隔符
wb_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*/_/g; s/^_//; s/_$//'
}

# Windows 原生程序（node.exe / 桌面端 exe）只认 G:/... 风格路径
wb_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# 桌面端登录态目录（平台差异集中在这里）
wb_auth_dir() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '%s' "${LOCALAPPDATA:-$HOME/AppData/Local}/CodeBuddyExtension/Data/Public/auth" ;;
    Darwin) printf '%s' "$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth" ;;
    *) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/CodeBuddyExtension/Data/Public/auth" ;;
  esac
}

# 定位 node（禁止硬编码版本号：运行时升级后仍可用）
wb_find_node() {
  [ -n "${WB_NODE_BIN:-}" ] && [ -x "$WB_NODE_BIN" ] && { printf '%s' "$WB_NODE_BIN"; return; }
  local n c
  n="$(command -v node 2>/dev/null)"
  if [ -n "$n" ]; then printf '%s' "$n"; return; fi
  for c in \
    "$HOME/.workbuddy/binaries/node/versions/current/node.exe" \
    "$HOME/.workbuddy-ai/binaries/node/versions/current/node.exe" \
    "$HOME"/.workbuddy/binaries/node/versions/*/node.exe \
    "$HOME"/.workbuddy-ai/binaries/node/versions/*/node.exe \
    /opt/homebrew/bin/node /usr/local/bin/node \
    "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$c" ] && { printf '%s' "$c"; return; }
  done
  printf ''
}

# 定位 python3 / python（仅结果解析与云端脚本需要，缺失不致命）
wb_find_python() {
  local c
  for c in "$(command -v python3 2>/dev/null)" "$(command -v python 2>/dev/null)" \
           "$HOME/.workbuddy/binaries/python/versions/current/python.exe" \
           "$HOME"/.workbuddy/binaries/python/versions/*/python.exe; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return; }
  done
  printf ''
}

# 定位 gh CLI（云端部署用）
wb_find_gh() {
  local c
  for c in "$(command -v gh 2>/dev/null)" \
           "$HOME/AppData/Local/Microsoft/WinGet/Packages/GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe/bin/gh.exe" \
           "/c/Program Files/GitHub CLI/gh.exe" \
           /opt/homebrew/bin/gh /usr/local/bin/gh; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return; }
  done
  printf ''
}

# 解析 JWT 字段（iat / exp / uid / nickname），失败输出 0
wb_jwt_field() {
  local tok="$1" field="$2" node_bin
  node_bin="$(wb_find_node)"
  [ -z "$node_bin" ] && { printf '0'; return; }
  WB_JWT="$tok" WB_FIELD="$field" "$node_bin" -e '
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

wb_days_left() {
  local tok="$1" node_bin
  node_bin="$(wb_find_node)"
  [ -z "$node_bin" ] && { printf '?'; return; }
  WB_JWT="$tok" "$node_bin" -e '
    const t=process.env.WB_JWT||"";const p=t.split(".");
    if(p.length<2){console.log("?");process.exit(0);}
    let s=p[1].replace(/-/g,"+").replace(/_/g,"/");s+="=".repeat((4-s.length%4)%4);
    try{const j=JSON.parse(Buffer.from(s,"base64").toString("utf8"));
      console.log(((j.exp*1000-Date.now())/86400000).toFixed(1));}catch(e){console.log("?");}
  ' 2>/dev/null || printf '?'
}
