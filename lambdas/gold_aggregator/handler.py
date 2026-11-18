import json
import os
from collections import defaultdict
from datetime import datetime, timezone
import boto3

ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")
SILVER_BUCKET = os.environ["SILVER_BUCKET"]
GOLD_BUCKET = os.environ["GOLD_BUCKET"]

s3 = boto3.client("s3", endpoint_url=ENDPOINT_URL)


def lambda_handler(event, context):
    paginator = s3.get_paginator("list_objects_v2")
    pages = paginator.paginate(Bucket=SILVER_BUCKET, Prefix="transactions/")

    all_records = []
    files_read = 0

    for page in pages:
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".jsonl"):
                continue
            body = s3.get_object(Bucket=SILVER_BUCKET, Key=key)["Body"].read().decode("utf-8")
            for line in body.strip().splitlines():
                if line.strip():
                    all_records.append(json.loads(line))
            files_read += 1

    if not all_records:
        return {"statusCode": 200, "message": "No silver records found", "files_read": 0}

    summary_by_currency = defaultdict(lambda: {
        "total_transactions": 0,
        "approved_count": 0,
        "declined_count": 0,
        "pending_count": 0,
        "gross_volume": 0.0,
        "approved_volume": 0.0,
        "high_value_alerts": 0,
    })

    for rec in all_records:
        ccy = rec["currency"]
        amount = float(rec["amount"])
        status = rec["status"].upper()

        bucket = summary_by_currency[ccy]
        bucket["total_transactions"] += 1
        bucket["gross_volume"] = round(bucket["gross_volume"] + amount, 2)

        if amount >= 10000.0:
            bucket["high_value_alerts"] += 1

        if status == "APPROVED":
            bucket["approved_count"] += 1
            bucket["approved_volume"] = round(bucket["approved_volume"] + amount, 2)
        elif status == "DECLINED":
            bucket["declined_count"] += 1
        else:
            bucket["pending_count"] += 1

    kpis = {}
    for ccy, stats in summary_by_currency.items():
        total = stats["total_transactions"]
        approved = stats["approved_count"]
        stats["approval_rate_pct"] = round((approved / total) * 100, 2) if total else 0.0
        stats["avg_ticket"] = round(stats["gross_volume"] / total, 2) if total else 0.0
        kpis[ccy] = stats

    generated_at = datetime.now(timezone.utc)
    report = {
        "generated_at": generated_at.isoformat(),
        "silver_files_aggregated": files_read,
        "total_records_aggregated": len(all_records),
        "kpis_by_currency": kpis,
    }

    latest_key = "kpis/financial_summary_latest.json"
    snapshot_key = f"kpis/history/financial_summary_{generated_at.strftime('%Y%m%dT%H%M%SZ')}.json"

    for target_key in (latest_key, snapshot_key):
        s3.put_object(
            Bucket=GOLD_BUCKET,
            Key=target_key,
            Body=json.dumps(report, indent=2).encode("utf-8"),
            ContentType="application/json",
        )

    print(f"[GOLD] Aggregated {len(all_records)} records across {files_read} files.")
    return {
        "statusCode": 200,
        "files_read": files_read,
        "records_aggregated": len(all_records),
        "gold_key": latest_key,
    }
