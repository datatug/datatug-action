"""Validate only scope-bound DataTug links before the Action echoes Markdown."""
import base64
import json
import os
import re
import sys


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate member")
        result[key] = value
    return result


def valid(result, project_dir, environ):
    link, reason = result.get("deepLink"), result.get("deepLinkReason")
    if link == "https://datatug.app" and reason == "hosted_result_reference_unsupported":
        return True
    if environ.get("DATATUG_PUBLISH_SUMMARY") != "true":
        return False
    if link == "" and reason in {
        "summary_publish_configuration_error", "summary_publish_incompatible_result",
        "summary_publish_auth_required", "summary_publish_unavailable",
        "summary_publish_denied", "summary_publish_invalid_response",
        "summary_publish_cancelled", "summary_publish_timeout",
    }:
        return True
    if reason != "hosted_summary_published" or not isinstance(link, str) or len(link) > 1024:
        return False
    with open(os.path.join(project_dir, "datatug-project.json"), encoding="utf-8") as stream:
        project = json.loads(stream.read(32769), object_pairs_hook=unique).get("id")
    space = environ.get("DATATUG_SUMMARY_SPACE", "")
    if not all(isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", v) for v in [space, project]):
        return False
    prefix = f"https://datatug.app/space/{space}/store/firestore/project/{project}/overview#check-summary="
    if not link.startswith(prefix):
        return False
    encoded = link[len(prefix):]
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,512}", encoded):
        return False
    raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    if base64.urlsafe_b64encode(raw).decode().rstrip("=") != encoded:
        return False
    ref = json.loads(raw, object_pairs_hook=unique)
    if not isinstance(ref, dict) or set(ref) != {"v", "environment", "summaryId"}:
        return False
    summary_id = ref["summaryId"]
    return (type(ref["v"]) is int and ref["v"] == 1 and
            ref["environment"] == environ.get("DATATUG_ENVIRONMENT") and
            isinstance(summary_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", summary_id) is not None and
            base64.urlsafe_b64encode(base64.urlsafe_b64decode(summary_id + "=")).decode().rstrip("=") == summary_id)


def main():
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            result = json.load(stream, object_pairs_hook=unique)
        return 0 if isinstance(result, dict) and valid(result, sys.argv[2], os.environ) else 1
    except (ValueError, TypeError, KeyError, OSError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
