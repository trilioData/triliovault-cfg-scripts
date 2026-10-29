#!/usr/bin/env python3
import argparse
import datetime
import html
import json
import os
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_RIGHT
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    KeepTogether,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "UNKNOWN"]
EXCLUDED_SEVERITIES = {"LOW"}
ALERT_SEVERITIES = {"CRITICAL", "HIGH"}
ALERT_COLOR = "#c62828"
SEVERITY_COLORS = {
    "CRITICAL": "#7b1fa2",
    "HIGH": "#c62828",
    "MEDIUM": "#ef6c00",
    "UNKNOWN": "#757575",
}
ROOT_GROUP = "(repository root)"
HEADER_BG = colors.HexColor("#37474f")
GRID = colors.HexColor("#b0bec5")
STRIPE = colors.HexColor("#f5f7f8")
TOTAL_BG = colors.HexColor("#eceff1")
PAGE = landscape(A4)
MARGIN = 12 * mm
WIDTH = PAGE[0] - 2 * MARGIN

styles = getSampleStyleSheet()
TITLE = ParagraphStyle("ReportTitle", parent=styles["Title"], fontSize=20, spaceAfter=6)
H1 = ParagraphStyle("Dir", parent=styles["Heading1"], fontSize=16, textColor=colors.white,
                    backColor=HEADER_BG, borderPadding=(4, 6, 4, 6), spaceBefore=6, spaceAfter=10,
                    keepWithNext=1)
H2 = ParagraphStyle("Section", parent=styles["Heading2"], fontSize=12, spaceBefore=10, spaceAfter=4,
                    keepWithNext=1)
BODY = ParagraphStyle("Body", parent=styles["BodyText"], fontSize=9, leading=11)
LEAD = ParagraphStyle("Lead", parent=BODY, keepWithNext=1)
CELL = ParagraphStyle("Cell", parent=BODY, fontSize=7.5, leading=9)
CODE = ParagraphStyle("Code", parent=CELL, fontName="Courier", fontSize=7, leading=8.5)
HEAD = ParagraphStyle("Head", parent=CELL, fontName="Helvetica-Bold", textColor=colors.white)
NUM = ParagraphStyle("Num", parent=CELL, alignment=TA_RIGHT)
ALERT_NUM = ParagraphStyle("AlertNum", parent=NUM, fontName="Helvetica-Bold",
                           textColor=colors.HexColor(ALERT_COLOR))
CLEAN = ParagraphStyle("Clean", parent=BODY, textColor=colors.HexColor("#2e7d32"), fontName="Helvetica-Bold")


def esc(value):
    return html.escape(str(value if value is not None else ""))


def para(value, style=CELL):
    return Paragraph(esc(value), style)


def code(value):
    return Paragraph(esc(value), CODE)


def normalize(target):
    target = target.replace("\\", "/")
    while target.startswith("./"):
        target = target[2:]
    return target


def group_of(target):
    return target.split("/", 1)[0] if "/" in target else ROOT_GROUP


def top_level_groups(repo_root):
    groups = sorted(
        entry.name
        for entry in os.scandir(repo_root)
        if entry.is_dir() and entry.name != ".git"
    )
    if any(entry.is_file() for entry in os.scandir(repo_root)):
        groups.insert(0, ROOT_GROUP)
    return groups


def lines(start, end):
    if not start:
        return ""
    return f":{start}" if not end or end == start else f":{start}-{end}"


def empty_bucket():
    return {"vulns": [], "misconfigs": [], "secrets": []}


def collect(results):
    findings = {}
    for result in results:
        target = normalize(result.get("Target", ""))
        bucket = findings.setdefault(group_of(target), empty_bucket())
        for vuln in result.get("Vulnerabilities") or []:
            if reportable(vuln):
                bucket["vulns"].append(dict(vuln, Target=target))
        for misconf in result.get("Misconfigurations") or []:
            if misconf.get("Status", "FAIL") == "FAIL" and reportable(misconf):
                bucket["misconfigs"].append(dict(misconf, Target=target))
        for secret in result.get("Secrets") or []:
            if reportable(secret):
                bucket["secrets"].append(dict(secret, Target=target))
    return findings


def reportable(item):
    return item.get("Severity", "UNKNOWN") not in EXCLUDED_SEVERITIES


def severity_of(item):
    severity = item.get("Severity", "UNKNOWN")
    return severity if severity in SEVERITIES else "UNKNOWN"


def severity_key(item):
    return SEVERITIES.index(severity_of(item)), item.get("Target", "")


def counts(bucket):
    tally = {severity: 0 for severity in SEVERITIES}
    for items in bucket.values():
        for item in items:
            tally[severity_of(item)] += 1
    return tally


def grid_table(header, rows, widths, severity_column=None, severities=None, total_row=False):
    data = [[Paragraph(esc(h), HEAD) for h in header]] + rows
    table = Table(data, colWidths=[w * WIDTH for w in widths], repeatRows=1)
    commands = [
        ("BACKGROUND", (0, 0), (-1, 0), HEADER_BG),
        ("GRID", (0, 0), (-1, -1), 0.4, GRID),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]
    for index in range(1, len(data)):
        if index % 2 == 0:
            commands.append(("BACKGROUND", (0, index), (-1, index), STRIPE))
    if severity_column is not None:
        for index, severity in enumerate(severities, start=1):
            commands.append(("BACKGROUND", (severity_column, index), (severity_column, index),
                             colors.HexColor(SEVERITY_COLORS[severity])))
    if total_row:
        commands.append(("BACKGROUND", (0, len(data) - 1), (-1, len(data) - 1), TOTAL_BG))
    table.setStyle(TableStyle(commands))
    return table


def alert(severity, count):
    return severity in ALERT_SEVERITIES and count > 0


def severity_cell(severity):
    return Paragraph(f'<font color="white"><b>{esc(severity)}</b></font>', CELL)


def summary_flowable(groups, findings):
    rows = []
    totals = {severity: 0 for severity in SEVERITIES}
    for group in groups:
        tally = counts(findings.get(group, empty_bucket()))
        for severity in SEVERITIES:
            totals[severity] += tally[severity]
        link = f'<a href="#{anchor(group)}" color="#1565c0">{esc(group)}</a>'
        rows.append([Paragraph(link, CELL)]
                    + [para(tally[s], ALERT_NUM if alert(s, tally[s]) else NUM) for s in SEVERITIES]
                    + [para(sum(tally.values()), NUM)])
    bold_num = ParagraphStyle("BoldNum", parent=NUM, fontName="Helvetica-Bold")
    rows.append([Paragraph("<b>Total</b>", CELL)]
                + [para(totals[s], ALERT_NUM if alert(s, totals[s]) else bold_num) for s in SEVERITIES]
                + [para(sum(totals.values()), bold_num)])
    widths = [0.36] + [0.128] * (len(SEVERITIES) + 1)
    return grid_table(["Directory"] + SEVERITIES + ["Total"], rows, widths, total_row=True), totals


def anchor(name):
    return "dir-" + "".join(c if c.isalnum() else "-" for c in name)


def vuln_flowable(items):
    items = sorted(items, key=severity_key)
    rows = [[severity_cell(severity_of(i)),
             Paragraph(f'<a href="{esc(i.get("PrimaryURL"))}" color="#1565c0">{esc(i.get("VulnerabilityID"))}</a>'
                       if i.get("PrimaryURL") else esc(i.get("VulnerabilityID")), CELL),
             para(i.get("PkgName")), para(i.get("InstalledVersion")), para(i.get("FixedVersion")),
             para(i.get("Title")), code(i.get("Target"))] for i in items]
    return grid_table(["Severity", "ID", "Package", "Installed", "Fixed", "Title", "File"], rows,
                      [0.08, 0.12, 0.12, 0.09, 0.09, 0.28, 0.22], 0, [severity_of(i) for i in items])


def misconfig_flowable(items):
    items = sorted(items, key=severity_key)
    rows = []
    for i in items:
        cause = i.get("CauseMetadata") or {}
        rows.append([severity_cell(severity_of(i)), para(i.get("AVDID") or i.get("ID")), para(i.get("Title")),
                     para(i.get("Message")),
                     code(i.get("Target", "") + lines(cause.get("StartLine"), cause.get("EndLine"))),
                     para(i.get("Resolution"))])
    return grid_table(["Severity", "ID", "Title", "Message", "File", "Resolution"], rows,
                      [0.08, 0.09, 0.18, 0.25, 0.22, 0.18], 0, [severity_of(i) for i in items])


def secret_flowable(items):
    items = sorted(items, key=severity_key)
    rows = [[severity_cell(severity_of(i)), para(i.get("RuleID")), para(i.get("Title")),
             code(i.get("Target", "") + lines(i.get("StartLine"), i.get("EndLine"))),
             code((i.get("Match") or "")[:200])] for i in items]
    return grid_table(["Severity", "Rule", "Title", "File", "Match (redacted by Trivy)"], rows,
                      [0.08, 0.14, 0.2, 0.26, 0.32], 0, [severity_of(i) for i in items])


def directory_flowables(number, group, bucket):
    heading = Paragraph(f'<a name="{anchor(group)}"/>{number}. {esc(group)}', H1)
    heading.outline_title = f"{number}. {group}"
    story = [heading]
    if not any(bucket.values()):
        story.append(Paragraph("No findings.", CLEAN))
        return [KeepTogether(story)]
    tally = counts(bucket)
    story.append(Paragraph(
        "Findings: " + ", ".join(f"{s} {tally[s]}" for s in SEVERITIES if tally[s]), LEAD))
    for title, items, render in (
        ("Vulnerabilities", bucket["vulns"], vuln_flowable),
        ("Misconfigurations", bucket["misconfigs"], misconfig_flowable),
        ("Secrets", bucket["secrets"], secret_flowable),
    ):
        if items:
            story.append(Paragraph(f"{title} ({len(items)})", H2))
            story.append(render(items))
    return story


class ReportDoc(SimpleDocTemplate):
    def afterFlowable(self, flowable):
        title = getattr(flowable, "outline_title", None)
        if title:
            key = anchor(title)
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(title, key, level=0)


def footer(text):
    def draw(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7)
        canvas.setFillColor(colors.HexColor("#607d8b"))
        canvas.drawString(MARGIN, 7 * mm, text)
        canvas.drawRightString(PAGE[0] - MARGIN, 7 * mm, f"Page {doc.page}")
        canvas.restoreState()
    return draw


def meta_rows(args, report):
    rows = [
        ("Repository", args.repository),
        ("Branch", args.branch),
        ("Commit", args.commit),
        ("Scanned at", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")),
        ("Scanners", "vulnerabilities, secrets, misconfigurations"),
        ("Severities", ", ".join(SEVERITIES)),
        ("Trivy version", (report.get("Trivy") or {}).get("Version", "")),
    ]
    if args.run_url:
        rows.append(("Workflow run", args.run_url))
    return rows


def write_pdf(path, title, meta, groups, findings):
    doc = ReportDoc(path, pagesize=PAGE, leftMargin=MARGIN, rightMargin=MARGIN,
                    topMargin=MARGIN, bottomMargin=14 * mm, title=title, author="T4O DevOps")
    meta_table = Table([[para(k, ParagraphStyle("MetaKey", parent=CELL, fontName="Helvetica-Bold")), para(v)]
                        for k, v in meta], colWidths=[0.18 * WIDTH, 0.82 * WIDTH])
    meta_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (0, -1), TOTAL_BG),
        ("GRID", (0, 0), (-1, -1), 0.4, GRID),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    summary, totals = summary_flowable(groups, findings)
    summary_heading = Paragraph("Summary by directory", H1)
    summary_heading.outline_title = "Summary by directory"
    story = [Paragraph(esc(title), TITLE), meta_table, Spacer(1, 6 * mm), summary_heading, summary, PageBreak()]
    for number, group in enumerate(groups, start=1):
        story.extend(directory_flowables(number, group, findings.get(group, empty_bucket())))
        story.append(Spacer(1, 4 * mm))
    stamp = f"{title} | {dict(meta).get('Branch', '')} | {dict(meta).get('Commit', '')[:12]}"
    doc.build(story, onFirstPage=footer(stamp), onLaterPages=footer(stamp))
    return totals


def write_email_summary(path, title, meta, groups, findings):
    cell = "border:1px solid #cfd8dc;padding:6px 8px;"
    head = cell + "background:#37474f;color:#ffffff;text-align:left;"
    num = cell + "text-align:right;"
    alert_num = num + f"font-weight:bold;color:{ALERT_COLOR};"
    total = num + "font-weight:bold;background:#eceff1;"
    alert_total = total + f"color:{ALERT_COLOR};"
    rows = []
    totals = {severity: 0 for severity in SEVERITIES}
    for group in groups:
        tally = counts(findings.get(group, empty_bucket()))
        for severity in SEVERITIES:
            totals[severity] += tally[severity]
        rows.append(f'<tr><td style="{cell}">{esc(group)}</td>'
                    + "".join(f'<td style="{alert_num if alert(s, tally[s]) else num}">{tally[s]}</td>'
                              for s in SEVERITIES)
                    + f'<td style="{num}">{sum(tally.values())}</td></tr>')
    rows.append(f'<tr><td style="{cell}font-weight:bold;background:#eceff1;">Total</td>'
                + "".join(f'<td style="{alert_total if alert(s, totals[s]) else total}">{totals[s]}</td>'
                          for s in SEVERITIES)
                + f'<td style="{total}">{sum(totals.values())}</td></tr>')
    meta_html = "".join(
        f'<tr><td style="padding:2px 12px 2px 0;font-weight:bold;">{esc(k)}</td><td>{esc(v)}</td></tr>'
        for k, v in meta)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            '<html><body style="font-family:Arial,Helvetica,sans-serif;color:#212121;">'
            f'<h2 style="font-size:20px;">{esc(title)}</h2>'
            f'<table style="font-size:13px;margin-bottom:16px;">{meta_html}</table>'
            '<table style="border-collapse:collapse;font-size:13px;">'
            f'<tr><th style="{head}">Directory</th>'
            + "".join(f'<th style="{head}">{s}</th>' for s in SEVERITIES)
            + f'<th style="{head}">Total</th></tr>'
            + "".join(rows)
            + '</table><p style="font-size:13px;">The full report, with a section for every '
            "directory, is attached as a PDF.</p></body></html>"
        )


def main():
    parser = argparse.ArgumentParser(description="Render a Trivy JSON report as a PDF grouped by top-level directory.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--pdf", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--repository", default="")
    parser.add_argument("--branch", default="")
    parser.add_argument("--commit", default="")
    parser.add_argument("--run-url", default="")
    args = parser.parse_args()

    with open(args.input, encoding="utf-8") as handle:
        report = json.load(handle)

    findings = collect(report.get("Results") or [])
    groups = top_level_groups(args.repo_root)
    groups += sorted(set(findings) - set(groups))
    title = f"Trivy security scan - {args.repository or 'repository'}"
    meta = meta_rows(args, report)

    write_pdf(args.pdf, title, meta, groups, findings)
    write_email_summary(args.summary, title, meta, groups, findings)
    print(f"Report written for {len(groups)} directories")
    return 0


if __name__ == "__main__":
    sys.exit(main())
