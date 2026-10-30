#!/usr/bin/env python3
"""Generate the COS Trilio dashboard from the OpenShift one.

Usage:
  convert_openshift_dashboard.py <monitoring-openshift TrilioGrafanaDashboard.json> <output .json>

Changes applied on top of the OpenShift dashboard:
  - every panel / variable uses the ${datasource} variable (COS names its
    Prometheus datasource after the Juju topology, so no fixed UID works)
  - Domain selector before Project Name: Charmed OpenStack has the "admin" and
    "services" projects in more than one domain
  - cloud-level protected instances use openstack_protected_vm_total, which
    counts a VM protected in several projects only once
  - tables hide the juju_* topology labels COS adds to every series
"""
import json
import re
import sys

COS_UID = "trilio-t4o-cos"
COS_TITLE = "Trilio OpenStack Backup Monitor T4O (COS)"
DS = {"type": "prometheus", "uid": "${datasource}"}


def walk(panels):
    for panel in panels:
        yield panel
        yield from walk(panel.get("panels", []))


def set_query(var, query):
    var["definition"] = query
    var["query"] = {"qryType": 4, "query": query,
                    "refId": "PrometheusVariableQueryEditor-VariableQuery"}
    var["current"] = {}
    var["options"] = []


def query_var(name, label, query, hide=None):
    var = {"type": "query", "name": name, "label": label, "datasource": DS,
           "refresh": 1, "regex": "", "includeAll": False}
    if hide is not None:
        var["hide"] = hide
    set_query(var, query)
    return var


def main(src, dst):
    with open(src) as f:
        dashboard = json.load(f)

    # Point everything that names a prometheus datasource at ${datasource}
    def fix_ds(obj):
        if isinstance(obj, dict):
            ds = obj.get("datasource")
            if isinstance(ds, dict) and ds.get("type") == "prometheus":
                obj["datasource"] = dict(DS)
            for value in obj.values():
                fix_ds(value)
        elif isinstance(obj, list):
            for value in obj:
                fix_ds(value)
    fix_ds(dashboard["panels"])

    for panel in walk(dashboard["panels"]):
        for target in panel.get("targets", []):
            expr = target.get("expr", "")
            # Cloud level (no project filter): dedupe VMs across projects.
            # sum() drops the job/instance/juju_* labels so it matches count(...)
            if "openstack_protected_vm" in expr and "$project_id" not in expr:
                target["expr"] = re.sub(r"sum\(\s*openstack_protected_vm\s*\)",
                                        "sum(openstack_protected_vm_total)", expr)
        if panel.get("type") == "table":
            overrides = panel.setdefault("fieldConfig", {}).setdefault("overrides", [])
            if not any(o["matcher"].get("options") == "juju_.*" for o in overrides):
                overrides.append({
                    "matcher": {"id": "byRegexp", "options": "juju_.*"},
                    "properties": [{"id": "custom.hidden", "value": True}],
                })

    variables = {v["name"]: v for v in dashboard["templating"]["list"]}
    datasource = variables["datasource"]
    datasource["query"] = "prometheus"
    project_name = variables["project_name"]
    project_id = variables["project_id"]
    project_name["datasource"] = dict(DS)
    project_id["datasource"] = dict(DS)
    set_query(project_name, 'label_values(openstack_identity_project_info'
                            '{domain_id="$domain_id", name!~"service|services"}, name)')
    set_query(project_id, 'label_values(openstack_identity_project_info'
                          '{domain_id="$domain_id", name="$project_name"}, id)')
    domain = query_var("domain", "Domain",
                       'label_values(openstack_identity_domain_info{name!="service_domain"}, name)')
    domain_id = query_var("domain_id", "Domain ID",
                          'label_values(openstack_identity_domain_info{name="$domain"}, id)', hide=2)
    others = [v for n, v in variables.items()
              if n not in ("datasource", "domain", "domain_id", "project_name", "project_id")]
    dashboard["templating"]["list"] = [datasource, domain, domain_id, project_name, project_id] + others

    dashboard.pop("__inputs", None)
    dashboard["id"] = None
    dashboard["uid"] = COS_UID
    dashboard["title"] = COS_TITLE
    dashboard["tags"] = sorted(set(dashboard.get("tags", [])) | {"trilio", "t4o", "cos"})

    text = json.dumps(dashboard, indent=2)
    leftover = re.findall(r'"type": "prometheus",\s*"uid": "(?!\$\{datasource\})([^"]*)"', text)
    if leftover:
        sys.exit("fixed prometheus datasource UIDs left in dashboard: %s" % sorted(set(leftover)))
    with open(dst, "w") as f:
        f.write(text + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
