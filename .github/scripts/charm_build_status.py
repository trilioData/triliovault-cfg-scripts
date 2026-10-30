#!/usr/bin/env python3
import argparse
import os
import re
import sys

JUJU_STATUSES = {
    "CLEAN-FAILED": "Clean failed",
    "BUILD-FAILED": "Build failed",
    "DIR-NOT-FOUND": "Charm directory not found",
}


def read_logs(paths):
    text = ""
    for path in paths:
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                text += handle.read() + "\n"
    return text


def uploaded_revision(text):
    match = (re.search(r"Uploaded as revision ([0-9]+)", text)
             or re.search(r"Revision ([0-9]+) of '[^']+' created", text))
    return match.group(1) if match else None


def classify(outcome, text):
    if outcome == "success":
        return "Built and published"
    if outcome in ("cancelled", "skipped"):
        return "Cancelled" if outcome == "cancelled" else "Not run"
    if "Not logged in to Charmhub" in text or "Charmhub credentials are expired or invalid" in text:
        return "Charmhub login failed"
    for marker, label in JUJU_STATUSES.items():
        if marker in text:
            return label
    revision = uploaded_revision(text)
    if revision:
        return f"Release failed (r{revision} uploaded)"
    if "PUBLISH-FAILED" in text or "Pack complete" in text:
        return "Upload failed"
    return "Build failed"


def main():
    parser = argparse.ArgumentParser(description="Classify the result of one charm build and publish job.")
    parser.add_argument("--outcome", required=True)
    parser.add_argument("logs", nargs="*")
    args = parser.parse_args()
    print(classify(args.outcome, read_logs(args.logs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
