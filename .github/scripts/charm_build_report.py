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


def channel_release(status, channel):
    track, _, risk = channel.rpartition("/")
    if risk not in RISKS:
        return "", "-"
    for candidate_risk in reversed(RISKS[:RISKS.index(risk) + 1]):
        revisions, details = set(), set()
        for entry in status or []:
            for mapping in entry.get("mappings") or []:
                for release in mapping.get("releases") or []:
                    if (release.get("channel") != f"{track}/{candidate_risk}" or release.get("status") != "open"
                            or release.get("revision") is None):
                        continue
                    resources = ", ".join(f"{r['name']} r{r['revision']}" for r in release.get("resources") or [])
                    revisions.add(release["revision"])
                    details.add(f"r{release['revision']}" + (f" ({resources})" if resources else ""))
        if revisions:
            cell = "<br>".join(esc(value) for value in sorted(details))
            if candidate_risk != risk:
                cell += f'<br><span style="color:{MUTED_COLOR};font-size:12px;">follows {esc(track)}/{esc(candidate_risk)}</span>'
            return ", ".join(f"r{revision}" for revision in sorted(revisions)), cell
    return "", "-"


def run_summary_html(channel, published, failed_charms, unchanged):
    published_text = ", ".join(f"<b>{esc(name)}</b> ({esc(revision) or 'revision unknown'})"
                               for name, revision in published) or "None"
    failed_text = ", ".join(f"<b>{esc(name)}</b>" for name in failed_charms) or "None"
    unchanged_text = ", ".join(f"<b>{esc(name)}</b> ({esc(channel)}: {esc(revision) or 'nothing released'})"
                               for name, revision in unchanged) or "None"
    label = "padding:4px 12px 4px 0;font-weight:bold;vertical-align:top;white-space:nowrap;"
    return (
        '<h3 style="font-size:16px;margin-bottom:4px;">Charms in this run</h3>'
        '<table style="font-size:13px;margin-bottom:16px;">'
        f'<tr><td style="{label}color:{OK_COLOR};">Built and published to {esc(channel)}</td><td>{published_text}</td></tr>'
        f'<tr><td style="{label}color:{FAIL_COLOR};">Build or publish failed</td><td>{failed_text}</td></tr>'
        f'<tr><td style="{label}color:{MUTED_COLOR};">Not built, no code change</td><td>{unchanged_text}</td></tr>'
        "</table>"
    )


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
        return f'<span style="color:{OK_COLOR};font-weight:bold;">Built and published</span>'
    if outcome is None:
        return f'<span style="color:{MUTED_COLOR};">Not built, no code change</span>'
    return f'<span style="color:{FAIL_COLOR};font-weight:bold;">Build or publish failed</span>'


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
    failed = False
    rows = []
    published, failed_charms, unchanged = [], [], []
    for name, store in args.charm:
        outcome = results.get(name, "failure") if name in selected else None
        failed = failed or (outcome is not None and outcome != "success")
        status, error = store_status(store)
        revision, cell = channel_release(status, args.channel)
        if status is None:
            cell = f'<span style="color:{MUTED_COLOR};">unavailable</span>'
            print(f"{store}: {error}", file=sys.stderr)
        if outcome is None:
            unchanged.append((name, revision))
        elif outcome == "success":
            published.append((name, revision))
        else:
            failed_charms.append(name)
        store_line = (f'<br><span style="color:{MUTED_COLOR};font-size:12px;">{esc(store)}</span>'
                      if store != name else "")
        rows.append(f'<tr><td style="{CELL}"><b>{esc(name)}</b>{store_line}</td>'
                    f'<td style="{CELL}">{outcome_cell(outcome)}</td>'
                    f'<td style="{CELL}">{cell}</td></tr>')

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
            + run_summary_html(args.channel, published, failed_charms, unchanged)
            + f'<table style="font-size:13px;margin-bottom:16px;">{meta_html}</table>'
            '<table style="border-collapse:collapse;font-size:13px;">'
            f'<tr><th style="{HEAD}">Charm</th><th style="{HEAD}">This run</th>'
            f'<th style="{HEAD}">{esc(args.channel)}</th></tr>'
            + "".join(rows) + "</table>"
            f'<p style="font-size:12px;color:{MUTED_COLOR};">The {esc(args.channel)} column shows the charm revision '
            "currently released on that channel in Charmhub, with its resource revisions.</p></body></html>"
        )
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"failed={'true' if failed else 'false'}\n")
    print(f"Report written for {len(rows)} charms, failed={failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
