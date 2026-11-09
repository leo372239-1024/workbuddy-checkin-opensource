#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WorkBuddy 每日签到（云端版，GitHub Actions）

只依赖 Python 标准库，无第三方依赖。
凭据通过环境变量（GitHub Secrets）注入，脚本不打印任何 token。

安全红线：
  - 不打印 accessToken / 任何凭据
  - 只请求腾讯官方接口
  - 幂等：今日已签到（today_checked_in 或 code=10001）都视为成功并安全退出
"""
import os
import sys
import json
import urllib.request
import urllib.error

API_BASE = (os.environ.get("WB_API_BASE") or "https://copilot.tencent.com").rstrip("/")
ACCESS_TOKEN = os.environ.get("WORKBUDDY_ACCESS_TOKEN", "")
UID = os.environ.get("WORKBUDDY_UID", "")
DOMAIN = os.environ.get("WORKBUDDY_DOMAIN", "")
ENTERPRISE_ID = os.environ.get("WORKBUDDY_ENTERPRISE_ID", "")

CHECK_STATUS_PATH = "/v2/billing/meter/checkin-status"
DAILY_CHECKIN_PATH = "/v2/billing/meter/daily-checkin"


def _call(path: str):
    """POST 请求，返回 (http_code, body_str)。"""
    url = API_BASE + path
    req = urllib.request.Request(url, data=b"{}", method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("Authorization", "Bearer " + ACCESS_TOKEN)
    if UID:
        req.add_header("X-User-Id", UID)
    if DOMAIN:
        req.add_header("X-Domain", DOMAIN)
    if ENTERPRISE_ID:
        req.add_header("X-Enterprise-Id", ENTERPRISE_ID)
        req.add_header("X-Tenant-Id", ENTERPRISE_ID)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def _finish(result: str, message: str, exit_code: int) -> int:
    """统一输出：机器可读标记行 + 人类可读信息。

    WB_RESULT 取值：
      ok_claimed   本次真实领取成功
      ok_already   今日已签到（幂等跳过）
      token_expired 令牌过期/无权限（HTTP 401/403）
      network_error 网络异常
      api_error    签到业务码异常
      no_token     Secret 未配置
    """
    print("WB_RESULT=%s" % result)
    print(message)
    return exit_code


def main() -> int:
    if not ACCESS_TOKEN:
        return _finish("no_token", "失败：缺少 WORKBUDDY_ACCESS_TOKEN（Secret 未配置）", 1)

    # 1. 查询签到状态（用于快速短路 + 探测 token 是否过期）
    code, body = _call(CHECK_STATUS_PATH)
    if code in (401, 403):
        return _finish(
            "token_expired",
            "失败：token 已过期或无权限（HTTP %d），请在本机重新回传最新 accessToken" % code,
            2,
        )
    if code == 0:
        return _finish("network_error", "失败：网络异常，无法连接签到接口", 1)

    # 2. 快速短路：状态接口明确表示今日已签到（today_checked_in 字段可能不可靠，
    #    因此仅作快速跳过，最终幂等兜底靠下方 daily-checkin 的业务码）
    if code == 200:
        try:
            checked = bool(json.loads(body).get("data", {}).get("today_checked_in"))
        except Exception:  # noqa: BLE001
            checked = False
        if checked:
            return _finish("ok_already", "今日已签到（状态接口确认），无需重复领取", 0)

    # 3. 执行签到。注意：daily-checkin 在"今日已签到"时返回 HTTP 400 + code=10001，
    #    因此这里不能把 HTTP != 200 当作失败，必须以响应体的业务码 code 为准。
    code, body = _call(DAILY_CHECKIN_PATH)
    if code in (401, 403):
        return _finish(
            "token_expired",
            "失败：token 已过期或无权限（HTTP %d），请在本机重新回传最新 accessToken" % code,
            2,
        )
    if code == 0:
        return _finish("network_error", "失败：签到请求网络异常", 1)

    try:
        data = json.loads(body)
    except Exception:  # noqa: BLE001
        return _finish("api_error", "失败：签到响应无法解析（HTTP %d）" % code, 1)

    biz_code = data.get("code")
    if biz_code == 0:
        d = data.get("data", {}) or {}
        return _finish(
            "ok_claimed",
            "签到成功：credit=%s streak_days=%s" % (d.get("credit"), d.get("streak_days")),
            0,
        )
    if biz_code == 10001:
        return _finish("ok_already", "今日已签到（接口 code=10001），无需重复领取", 0)
    return _finish("api_error", "失败：签到未成功 code=%s msg=%s" % (biz_code, data.get("msg")), 1)


if __name__ == "__main__":
    sys.exit(main())
