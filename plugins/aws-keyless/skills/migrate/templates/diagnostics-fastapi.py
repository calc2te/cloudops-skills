"""AWS credential diagnostics endpoint — FastAPI template.

Answers two questions on one screen: *who am I calling AWS as* and *does each call work*.
Add it before the migration and you get a clean before/after (user/... -> assumed-role/...).

HOW TO ADAPT: the CHECKS list below is a menu. Keep `identity` — it is the whole point — and
then keep only the checks for services this app actually uses. Delete the rest; a check for a
service you do not use is noise at best and a reason to over-grant the policy at worst.

Guard: non-production only + a token (X-Diag-Token header or ?token=). Anything else 404s.
Cost: whatever the checks you keep cost. Keep them trivial (1-token replies, HEAD-style calls).
Note: ?token= lands in access logs — rotate the token or delete the endpoint when you are done.

Credentials are never specified here. Showing whatever the SDK default chain resolves *is* the test.
"""

import hmac
import time
from html import escape

import boto3
from fastapi import APIRouter, Request
from starlette.responses import HTMLResponse, JSONResponse

from app.config import settings  # environment, diag token, and this app's resource names

router = APIRouter()


# ── checks ───────────────────────────────────────────────────────────────────
# Each returns a small dict (or string) shown in the result. Raise on failure.

def check_identity():
    """Always keep this one: it names the principal the SDK resolved."""
    return boto3.client("sts").get_caller_identity()["Arn"]


def check_s3():
    s3 = boto3.client("s3", region_name=settings.s3_region)
    key = "diag/aws-check.txt"                      # fixed key: overwritten, never accumulates
    body = str(time.time()).encode()
    s3.put_object(Bucket=settings.s3_bucket, Key=key, Body=body)
    got = s3.get_object(Bucket=settings.s3_bucket, Key=key)["Body"].read()
    return {"bucket": settings.s3_bucket, "roundtrip": got == body}


def check_dynamodb():
    table = boto3.resource("dynamodb", region_name=settings.ddb_region).Table(settings.ddb_table)
    key = next(k["AttributeName"] for k in table.key_schema if k["KeyType"] == "HASH")
    # query a partition that cannot exist: proves permission without touching real data
    from boto3.dynamodb.conditions import Key
    resp = table.query(KeyConditionExpression=Key(key).eq("__diag__"), Limit=1)
    return {"table": settings.ddb_table, "count": resp["Count"]}


def check_sqs():
    sqs = boto3.client("sqs", region_name=settings.sqs_region)
    attrs = sqs.get_queue_attributes(
        QueueUrl=settings.sqs_url, AttributeNames=["ApproximateNumberOfMessages"]
    )["Attributes"]
    return {"queue": settings.sqs_url.rsplit("/", 1)[-1], "messages": attrs.get("ApproximateNumberOfMessages")}


def check_bedrock():
    resp = boto3.client("bedrock-runtime", region_name=settings.bedrock_region).converse(
        modelId=settings.bedrock_model_id,
        messages=[{"role": "user", "content": [{"text": "ping"}]}],
        inferenceConfig={"maxTokens": 1},
    )
    return {"model": settings.bedrock_model_id, "stopReason": resp.get("stopReason")}


# Keep identity + the ones that apply. Order is display order.
CHECKS = [
    ("identity", check_identity),
    ("s3", check_s3),
    # ("dynamodb", check_dynamodb),
    # ("sqs", check_sqs),
    # ("bedrock", check_bedrock),
]

# Deliberately not included: anything with side effects a reader would not expect —
# sending email, publishing to a topic, starting a job. Verify those through the feature itself.


def run_checks() -> dict:
    results: dict = {}

    for name, fn in CHECKS:
        started = time.monotonic()
        try:
            detail = fn()  # run first: dict literals evaluate top-down, so timing must wrap the call
            results[name] = {"ok": True, "ms": int((time.monotonic() - started) * 1000), "detail": detail}
        except Exception as e:
            err = getattr(e, "response", {}).get("Error", {}) if hasattr(e, "response") else {}
            results[name] = {
                "ok": False,
                "ms": int((time.monotonic() - started) * 1000),
                "error": err.get("Code") or type(e).__name__,
                "message": (err.get("Message") or str(e))[:300],
            }

    creds = boto3.Session().get_credentials()
    return {
        "environment": settings.environment,
        "credential_source": creds.method if creds else "none",
        "all_ok": all(r["ok"] for r in results.values()),
        "checks": results,
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
