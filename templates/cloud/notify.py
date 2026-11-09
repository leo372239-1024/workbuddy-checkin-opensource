#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WorkBuddy 签到失败告警（GitHub Actions 侧）

用法：
  python notify.py --failure      # 签到失败/令牌过期时立即告警

设计纪律（都是踩过坑换来的）：
  - **只发失败，不做临期预警。** 临期提醒会让人麻木，真到过期那天反而不看。
  - **双通道降级**：SMTP 邮件优先 -> 失败自动回退 GitHub Issue（用内置 GITHUB_TOKEN，
    无需额外凭据）。只写邮件通道的话，凭据一过期，告警本身先哑掉。
  - 正文直接给「两步处置」，不要让收到邮件的人自己去查。

所需 Secrets（邮件通道，全部可选；配了才走邮件）：
  MAIL_SMTP_HOST / MAIL_SMTP_PORT / MAIL_USERNAME / MAIL_PASSWORD / MAIL_FROM / MAIL_TO
未配置邮件时自动走 Issue 通道。

安全红线：不打印 accessToken；仅输出判定结论与剩余天数。
"""
import os
import sys
import json
import ssl
import base64
import smtplib
import urllib.request
from datetime import datetime, timezone, timedelta
from email.message import EmailMessage

BJ = timezone(timedelta(hours=8))

ACCOUNT = os.environ.get("WB_ACCOUNT_NAME", "当前账号")
CLOUD_REPO = os.environ.get("GITHUB_REPOSITORY", "unknown")


def _now():
    return datetime.now(BJ).strftime("%Y-%m-%d %H:%M:%S")


def _tail(path, lines=25):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-lines:]).strip()
    except Exception:
        return "(无日志)"


def jwt_days_left():
    """解析 accessToken 的 exp，返回剩余天数（float）；无法解析返回 None。"""
    token = (os.environ.get("WORKBUDDY_ACCESS_TOKEN") or "").strip()
    parts = token.split(".")
    if len(parts) != 3:
        return None
    try:
        seg = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(seg))
        exp = payload.get("exp")
        if not exp:
            return None
        return (datetime.fromtimestamp(exp, BJ) - datetime.now(BJ)).total_seconds() / 86400.0
    except Exception:
        return None


def send_mail(subject, body):
    """返回 (ok, err)。凭据缺失时 ok=False 且 err 说明原因。"""
    host = (os.environ.get("MAIL_SMTP_HOST") or "").strip()
    user = (os.environ.get("MAIL_USERNAME") or "").strip()
    pwd = os.environ.get("MAIL_PASSWORD") or ""
    to = (os.environ.get("MAIL_TO") or "").strip()
    frm = (os.environ.get("MAIL_FROM") or user or to).strip()

    if not (host and user and pwd and to):
        return False, "邮件通道未配置（MAIL_SMTP_HOST/USERNAME/PASSWORD/TO）"

    try:
        port = int(os.environ.get("MAIL_SMTP_PORT") or 465)
    except ValueError:
        port = 465

    msg = EmailMessage()
    msg["From"] = frm
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)

    ctx = ssl.create_default_context()
    try:
        if port == 465:
            server = smtplib.SMTP_SSL(host, port, timeout=30, context=ctx)
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            server.ehlo()
            if port in (25, 587):
                try:
                    server.starttls(context=ctx)
                    server.ehlo()
                except Exception:
                    pass
        with server:
            server.login(user, pwd)
            server.send_message(msg)
        return True, ""
    except Exception as e:  # noqa: BLE001
        return False, "%s: %s" % (type(e).__name__, e)


def create_issue(title, body):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not (CLOUD_REPO and token):
        return False, "缺少 GITHUB_REPOSITORY / GITHUB_TOKEN"
    req = urllib.request.Request(
        "https://api.github.com/repos/%s/issues" % CLOUD_REPO,
        data=json.dumps({"title": title, "body": body}).encode("utf-8"),
        method="POST",
    )
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return True, "#%s" % json.loads(r.read().decode("utf-8")).get("number")
    except Exception as e:  # noqa: BLE001
        return False, "%s: %s" % (type(e).__name__, e)


def deliver(subject, body):
    """邮件优先，失败回退 GitHub Issue。两步都失败才返回非 0。

    WB_DRY_RUN=1 时仅打印告警内容、不发送，便于本地校验文案。
    """
    if os.environ.get("WB_DRY_RUN") == "1":
        print("=== DRY RUN（不发送）===")
        print("Subject: %s" % subject)
        print(body)
        return 0
    ok, err = send_mail(subject, body)
    if ok:
        print("✅ 已发送邮件告警 -> %s" % os.environ.get("MAIL_TO"))
        return 0
    print("⚠️ 邮件通道不可用：%s" % err)
    ok2, info = create_issue(
        subject, body + "\n\n---\n（邮件通道不可用，已回退为 Issue 告警：%s）" % err
    )
    if ok2:
        print("✅ 已创建 Issue 告警 %s" % info)
        return 0
    print("❌ 告警全部通道失败：%s" % info)
    return 1


def main():
    run_url = "%s/%s/actions/runs/%s" % (
        os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
        CLOUD_REPO,
        os.environ.get("GITHUB_RUN_ID", ""),
    )

    exit_code = (os.environ.get("WB_EXIT_CODE") or "").strip()
    log = _tail(os.environ.get("WB_LOG_FILE", "checkin.log"))
    expired = exit_code == "2" or "已过期" in log or "401" in log

    if expired:
        subject = "🔴 WorkBuddy 签到失败：token 已过期（需桌面端重新登录后回传）"
        reason = "令牌已过期或无权限（HTTP 401/403），云端无法签到。"
    else:
        subject = "🔴 WorkBuddy 签到失败（退出码 %s）" % (exit_code or "?")
        reason = "签到接口返回异常，需人工确认。"

    d = jwt_days_left()
    body = (
        "%s\n\n"
        "账号：%s\n"
        "判定时间：%s\n"
        "仓库：%s\n"
        "退出码：%s\n"
        "token 剩余天数：%s\n\n"
        "最近日志：\n%s\n\n"
        "处理步骤（两步，缺一不可）：\n"
        "  1. 打开 WorkBuddy 桌面端，用「%s」账号重新登录。\n"
        "     说明：token 只能由桌面端登录时产生，单纯跑脚本无法凭空续期。\n"
        "     （自动刷新只前移 iat，不后延 exp，所以到期只能靠重新登录越过）\n"
        "  2. 登录完成后，在本机 skill 仓库运行一次：\n"
        "     bash scripts/snapshot.sh && bash scripts/push-secret.sh\n"
        "     这一步把新令牌搬进本地快照并回传云端 Secrets。\n\n"
        "完成后，云端下一次定时任务即自动恢复；\n"
        "也可在 Actions 页面手动 Run workflow 立即验证一次。\n\n"
        "运行详情：%s\n"
    ) % (
        reason,
        ACCOUNT,
        _now(),
        CLOUD_REPO,
        exit_code or "?",
        "无法解析" if d is None else "%.1f 天" % d,
        log,
        ACCOUNT,
        run_url,
    )
    return deliver(subject, body)


if __name__ == "__main__":
    sys.exit(main())
