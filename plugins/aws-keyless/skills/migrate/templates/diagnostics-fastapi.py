"""AWS credential diagnostics endpoint — FastAPI template.

Answers two questions on one screen: *who am I calling AWS as* and *does each call work*.
Add it before the migration and you get a clean before/after (user/... -> assumed-role/...).

Guard: non-production only + a token (X-Diag-Token header or ?token=). Anything else 404s.
Cost: one 1-token model reply plus one overwrite of a fixed S3 key.
Note: ?token= lands in access logs — rotate the token or delete the endpoint when you are done.

Credentials are never specified here. Showing whatever the SDK default chain resolves *is* the test.
"""

import hmac
import time
from html import escape

import boto3
from fastapi import APIRouter, Request
from starlette.responses import HTMLResponse, JSONResponse

from app.config import settings  # environment, app_diag_token, s3_bucket, s3_region

router = APIRouter()

_MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
_S3_KEY = "diag/aws-check.txt"


def _run(checks: dict, name: str, fn) -> None:
    started = time.monotonic()
    try:
        detail = fn()  # run first: array/dict literals evaluate top-down, so timing must wrap the call
        checks[name] = {"ok": True, "ms": int((time.monotonic() - started) * 1000), "detail": detail}
    except Exception as e:
        err = getattr(e, "response", {}).get("Error", {}) if hasattr(e, "response") else {}
        checks[name] = {
            "ok": False,
            "ms": int((time.monotonic() - started) * 1000),
            "error": err.get("Code") or type(e).__name__,
            "message": (err.get("Message") or str(e))[:300],
        }


def run_checks() -> dict:
    checks: dict = {}

    _run(checks, "identity", lambda: boto3.client("sts").get_caller_identity()["Arn"])

    def bedrock():
        resp = boto3.client("bedrock-runtime", region_name="us-west-2").converse(
            modelId=_MODEL_ID,
            messages=[{"role": "user", "content": [{"text": "ping"}]}],
            inferenceConfig={"maxTokens": 1},
        )
        return {"model": _MODEL_ID, "stopReason": resp.get("stopReason")}

    def s3_roundtrip():
        s3 = boto3.client("s3", region_name=settings.s3_region)
        body = str(time.time()).encode()
        s3.put_object(Bucket=settings.s3_bucket, Key=_S3_KEY, Body=body)
        got = s3.get_object(Bucket=settings.s3_bucket, Key=_S3_KEY)["Body"].read()
        return {"bucket": settings.s3_bucket, "roundtrip": got == body}

    _run(checks, "bedrock_converse", bedrock)
    _run(checks, "s3_put_get", s3_roundtrip)
    # Add only what this service uses (DynamoDB read, SQS attributes, KB retrieve...).
    # Write checks should overwrite a fixed key or query a nonexistent partition — never dirty real data.

    creds = boto3.Session().get_credentials()
    return {
        "environment": settings.environment,
        "credential_source": f"{creds.method}" if creds else "none",
        "all_ok": all(c["ok"] for c in checks.values()),
        "checks": checks,
    }


@router.get("/test/aws")
async def test_aws(request: Request):
    token = request.headers.get("X-Diag-Token") or request.query_params.get("token", "")
    if (
        settings.environment not in ("stage", "dev")
        or not settings.app_diag_token
        or not hmac.compare_digest(token, settings.app_diag_token)
    ):
        return JSONResponse(status_code=404, content={"detail": "Not Found"})

    data = run_checks()
    headers = {"Cache-Control": "no-store"}

    if request.query_params.get("format") == "json" or "text/html" not in request.headers.get("accept", ""):
        return JSONResponse(content=data, headers=headers)

    rows = "".join(
        f"<tr><td>{'✅' if c['ok'] else '❌'}</td><td>{escape(n)}</td><td>{c['ms']} ms</td>"
        f"<td><code>{escape(str(c.get('detail') or c['error'] + ': ' + c['message']))}</code></td></tr>"
        for n, c in data["checks"].items()
    )
    who = data["checks"]["identity"].get("detail", "(failed)")
    return HTMLResponse(
        f"<!doctype html><meta charset='utf-8'><title>AWS diagnostics</title>"
        f"<body style='font-family:system-ui;margin:2rem;max-width:60rem'>"
        f"<h1 style='font-size:1.3rem'>AWS credential diagnostics — {escape(data['environment'])}</h1>"
        f"<p style='background:#f3f4f6;padding:.8rem;border-radius:.5rem'>calling as: <code>{escape(str(who))}</code><br>"
        f"credential source: <code>{escape(data['credential_source'])}</code></p>"
        f"<p><b>{'all ok' if data['all_ok'] else 'failures'}</b></p>"
        f"<table style='border-collapse:collapse;width:100%'>{rows}</table></body>",
        headers=headers,
    )
