#!/usr/bin/env python3
import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys

RISKS = ["stable", "candidate", "beta", "edge"]
OK_COLOR = "#2e7d32"
FAIL_COLOR = "#c62828"
MUTED_COLOR = "#757575"
CELL = "border:1px solid #cfd8dc;padding:6px 8px;vertical-align:top;"
HEAD = CELL + "background:#37474f;color:#ffffff;text-align:left;"
JIRA_PATTERN = re.compile(r"\bTVAULT-[0-9]+\b")
PR_PATTERN = re.compile(r"Merge pull request #([0-9]+)")


def esc(value):
    return html.escape(str(value if value is not None else ""))


def charm_input(value):
    name, sep, store = value.partition("=")
    if not sep or not name or not store:
        raise argparse.ArgumentTypeError("expected NAME=STORE_NAME")
    return name, store


def load_results(directory):
    results = {}
    if directory and os.path.isdir(directory):
        for entry in os.scandir(directory):
            if entry.name.endswith(".json"):
                with open(entry.path, encoding="utf-8") as handle:
                    data = json.load(handle)
                results[data["charm"]] = data.get("outcome", "unknown")
    return results


def store_status(store):
    try:
        output = subprocess.run(["charmcraft", "status", store, "--format", "json"], check=True,
                                capture_output=True, text=True, timeout=300).stdout
        return json.loads(output), ""
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        return None, detail.strip().splitlines()[-1] if detail.strip() else "charmcraft status failed"


def channel_cells(status, track):
    cells = {risk: set() for risk in RISKS}
    for entry in status or []:
        if entry.get("track") != track:
            continue
        for mapping in entry.get("mappings") or []:
            for release in mapping.get("releases") or []:
                risk = release.get("channel", "").split("/")[-1]
                if risk not in cells:
                    continue
                if release.get("status") == "tracking":
                    cells[risk].add("\u2191")
                    continue
                if release.get("status") != "open" or release.get("revision") is None:
                    continue
                resources = ", ".join(f"{r['name']} r{r['revision']}" for r in release.get("resources") or [])
                cells[risk].add(f"r{release['revision']}" + (f" ({resources})" if resources else ""))
    return {risk: "<br>".join(esc(value) for value in sorted(values)) or "-" for risk, values in cells.items()}


def changes(path):
    if not path or not os.path.isfile(path):
        return [], []
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    jiras = sorted(set(JIRA_PATTERN.findall(text)), key=lambda key: int(key.split("-")[1]))
    prs = sorted(set(PR_PATTERN.findall(text)), key=int)
    return jiras, prs


def links_html(jiras, prs, jira_url, repo_url):
    jira_links = ", ".join(f'<a href="{esc(jira_url.rstrip("/"))}/{esc(key)}">{esc(key)}</a>' for key in jiras) or "-"
    pr_links = ", ".join(f'<a href="{esc(repo_url.rstrip("/"))}/pull/{esc(number)}">#{esc(number)}</a>'
                         for number in prs) or "-"
    return (f'<tr><td style="padding:2px 12px 2px 0;font-weight:bold;">Jira</td><td>{jira_links}</td></tr>'
            f'<tr><td style="padding:2px 12px 2px 0;font-weight:bold;">Merged PRs</td><td>{pr_links}</td></tr>')


def outcome_cell(outcome):
    if outcome == "success":
        return f'<span style="color:{OK_COLOR};font-weight:bold;">Published</span>'
    if outcome is None:
        return f'<span style="color:{MUTED_COLOR};">Not built (unchanged)</span>'
    return f'<span style="color:{FAIL_COLOR};font-weight:bold;">Failed</span>'


def main():
    parser = argparse.ArgumentParser(description="Render the charm build and publish email report.")
    parser.add_argument("--title", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--charm", required=True, action="append", type=charm_input)
    parser.add_argument("--selected", required=True)
    parser.add_argument("--results", default="")
    parser.add_argument("--summary", required=True)
    parser.add_argument("--branch", default="")
    parser.add_argument("--commit", default="")
    parser.add_argument("--trigger", default="")
    parser.add_argument("--run-url", default="")
    parser.add_argument("--changes", default="")
    parser.add_argument("--jira-url", default="")
    parser.add_argument("--repo-url", default="")
    args = parser.parse_args()

    selected = set(json.loads(args.selected))
    results = load_results(args.results)
    track = args.channel.split("/")[0]
    failed = False
    rows = []
    for name, store in args.charm:
        outcome = results.get(name, "failure") if name in selected else None
        failed = failed or (outcome is not None and outcome != "success")
        status, error = store_status(store)
        cells = channel_cells(status, track)
        if status is None:
            cells = {risk: f'<span style="color:{MUTED_COLOR};">unavailable</span>' for risk in RISKS}
            print(f"{store}: {error}", file=sys.stderr)
        store_line = (f'<br><span style="color:{MUTED_COLOR};font-size:12px;">{esc(store)}</span>'
                      if store != name else "")
        rows.append(f'<tr><td style="{CELL}"><b>{esc(name)}</b>{store_line}</td>'
                    f'<td style="{CELL}">{outcome_cell(outcome)}</td>'
                    + "".join(f'<td style="{CELL}">{cells[risk]}</td>' for risk in RISKS) + "</tr>")

    meta = [
        ("Released to", args.channel),
        ("Branch", args.branch),
        ("Commit", args.commit),
        ("Trigger", args.trigger),
        ("Report time", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")),
        ("Workflow run", args.run_url),
    ]
    meta_html = "".join(f'<tr><td style="padding:2px 12px 2px 0;font-weight:bold;">{esc(k)}</td><td>{esc(v)}</td></tr>'
                        for k, v in meta if v)
    jiras, prs = changes(args.changes)
    meta_html += links_html(jiras, prs, args.jira_url, args.repo_url)
    verdict = (f'<p style="font-size:14px;font-weight:bold;color:{FAIL_COLOR};">One or more charms failed to build or publish.</p>'
               if failed else
               f'<p style="font-size:14px;font-weight:bold;color:{OK_COLOR};">All built charms were published to {esc(args.channel)}.</p>')
    with open(args.summary, "w", encoding="utf-8") as handle:
        handle.write(
            '<html><body style="font-family:Arial,Helvetica,sans-serif;color:#212121;">'
            f'<h2 style="font-size:20px;">{esc(args.title)}</h2>'
            + verdict
            + f'<table style="font-size:13px;margin-bottom:16px;">{meta_html}</table>'
            '<table style="border-collapse:collapse;font-size:13px;">'
            f'<tr><th style="{HEAD}">Charm</th><th style="{HEAD}">This run</th>'
            + "".join(f'<th style="{HEAD}">{esc(track)}/{risk}</th>' for risk in RISKS)
            + "</tr>" + "".join(rows) + "</table>"
            f'<p style="font-size:12px;color:{MUTED_COLOR};">Channel columns show the charm revision currently '
            "released on Charmhub, with its resource revisions.</p></body></html>"
        )
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"failed={'true' if failed else 'false'}\n")
    print(f"Report written for {len(rows)} charms, failed={failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
