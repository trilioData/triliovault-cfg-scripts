#!/usr/bin/env python3
"""Deploy TrilioVault onto a Sunbeam Canonical OpenStack cloud.

    ./deploy_trilio.py ctlplane     # run in/against the "openstack" k8s model
    ./deploy_trilio.py dataplane    # run in/against the "openstack-machines" model
    ./deploy_trilio.py all          # both, in order

The bundles deploy Trilio applications only. Everything that touches one of
Sunbeam's own applications -- the relations to mysql / rabbitmq / keystone /
traefik / openstack-hypervisor / microceph, and the cross-model offers -- is
done here with `juju integrate`, which adds a relation WITHOUT reconciling the
application's revision or scale. That is the whole point: a bundle that names
an existing application will try to move it to the revision the bundle states,
which is how TVAULT-7644 downgraded microceph on the QA cloud.

Safe to re-run. Deploys, offers, consumes and relations are all skipped if they
already exist.
"""

import json
import os
import subprocess
import sys

CTLPLANE_BUNDLE = "trilio-ctlplane-bundle.yaml"
DATAPLANE_BUNDLE = "trilio-dataplane-bundle.yaml"

# (trilio endpoint, Sunbeam application, its endpoint)
CTLPLANE_RELATIONS = [
    ("trilio-wlm-k8s:database", "mysql", "database"),
    ("trilio-wlm-k8s:amqp", "rabbitmq", "amqp"),
    ("trilio-wlm-k8s:identity-service", "keystone", "identity-service"),
    ("trilio-wlm-k8s:ingress-internal", "traefik", "ingress"),
    ("trilio-wlm-k8s:ingress-public", "traefik-public", "ingress"),
    # Without the CA, keystonemiddleware fails TLS verification against
    # Sunbeam's HTTPS Keystone and every API request returns 503.
    ("trilio-wlm-k8s:receive-ca-cert", "keystone", "send-ca-cert"),
    ("trilio-dm-api-k8s:database", "mysql", "database"),
    ("trilio-dm-api-k8s:amqp", "rabbitmq", "amqp"),
    ("trilio-dm-api-k8s:identity-service", "keystone", "identity-service"),
    ("trilio-dm-api-k8s:ingress-internal", "traefik", "ingress"),
    ("trilio-dm-api-k8s:ingress-public", "traefik-public", "ingress"),
    ("trilio-dm-api-k8s:receive-ca-cert", "keystone", "send-ca-cert"),
]

# Offers the data plane consumes. `juju offer app:endpoint` names the offer
# after the APPLICATION unless told otherwise -- both keystone offers would be
# called "keystone" and the second would clobber the first, so the explicit
# name is required, not cosmetic.
CTLPLANE_OFFERS = [
    ("rabbitmq", "amqp", "rabbitmq"),
    ("keystone", "identity-credentials", "keystone-credentials"),
    ("keystone", "send-ca-cert", "cert-distributor"),
]

DATAPLANE_RELATIONS = [
    # Subordinate binding to the compute principal. Without it the charm never
    # gets a unit on any compute node.
    ("trilio-data-mover:juju-info", "openstack-hypervisor", "juju-info"),
    ("trilio-data-mover:amqp", "rabbitmq", "amqp"),
    ("trilio-data-mover:identity-credentials",
     "keystone-credentials", "identity-credentials"),
    ("trilio-data-mover:receive-ca-cert", "cert-distributor", "send-ca-cert"),
    # Optional: a Sunbeam cloud on local/LVM storage has no microceph at all,
    # and the charm gates its [ceph] config off when no pools are granted.
    ("trilio-data-mover:ceph", "microceph", "ceph"),
]


def run(args, check=True):
    """Run a juju command. stderr is kept separate so it never lands in JSON."""
    p = subprocess.run(["juju"] + args, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise SystemExit("FAILED: juju %s\n%s" % (" ".join(args), p.stderr.strip()))
    return p


def resolve_model(name):
    """Sunbeam models are owner-qualified: 'openstack-machines' alone is not
    accepted by juju, 'admin/openstack-machines' is."""
    p = run(["models", "--format=json"])
    for m in json.loads(p.stdout).get("models", []):
        full = m.get("name", "")
        if full == name or full.split("/")[-1] == name:
            return full
    raise SystemExit("model %r not found. Check 'juju models'." % name)


def status(model):
    return json.loads(run(["status", "-m", model, "--format=json"]).stdout)


def integrate(model, trilio_ep, other_app, other_ep, present):
    label = "%s <-> %s:%s" % (trilio_ep, other_app, other_ep)
    if other_app not in present:
        print("  skip    %s  (%s not in this cloud)" % (label, other_app))
        return True
    p = run(["integrate", "-m", model, trilio_ep,
             "%s:%s" % (other_app, other_ep)], check=False)
    if p.returncode == 0:
        print("  related %s" % label)
        return True
    if "already exists" in p.stderr:
        print("  ok      %s  (already related)" % label)
        return True
    print("  ERROR   %s\n          %s" % (label, p.stderr.strip()))
    return False


def deploy_bundle(model, bundle, apps, trust=False):
    """Skip the deploy once the applications are there -- re-deploying a bundle
    would reconcile our own charms' revisions on every re-run."""
    present = status(model).get("applications", {})
    if all(a in present for a in apps):
        print("  ok      %s already deployed" % bundle)
        return
    # juju deploy will not accept an absolute path outside the working
    # directory for a bundle ("no charm was found"), hence the leading "./"
    # and the chdir in main().
    cmd = ["deploy", "-m", model, "./" + bundle]
    if trust:
        # The k8s charms patch their own StatefulSets via lightkube to get
        # /dev/fuse for s3vaultfuse. Without --trust the bundle's own
        # "trust: true" is not honoured and the patch fails on RBAC.
        cmd.append("--trust")
    run(cmd)
    print("  deployed %s" % bundle)


def do_ctlplane(model):
    print("\n== Control plane -> %s ==" % model)
    deploy_bundle(model, CTLPLANE_BUNDLE,
                  ["trilio-wlm-k8s", "trilio-dm-api-k8s"], trust=True)

    present = status(model).get("applications", {})
    rc = 0
    print("\n-- relations to Sunbeam's applications --")
    for trilio_ep, app, ep in CTLPLANE_RELATIONS:
        rc |= not integrate(model, trilio_ep, app, ep, present)

    print("\n-- offers for the data plane --")
    existing = json.loads(run(["offers", "-m", model, "--format=json"]).stdout or "{}")
    for app, ep, name in CTLPLANE_OFFERS:
        if name in existing:
            print("  ok      %s (already offered)" % name)
            continue
        if app not in present:
            print("  skip    %s  (%s not in this cloud)" % (name, app))
            continue
        # Bare owner/model here: a controller-qualified model inline is
        # rejected with 'user name ... not valid'.
        run(["offer", "%s.%s:%s" % (model, app, ep), name])
        print("  offered %s" % name)
    return rc


def do_dataplane(model, ctl_model):
    print("\n== Data plane -> %s ==" % model)
    present = status(model).get("applications", {})
    if "openstack-hypervisor" not in present:
        raise SystemExit(
            "openstack-hypervisor not found in %s.\ntrilio-data-mover is a "
            "subordinate and cannot get a unit without it. This script does "
            "not install it -- it is Sunbeam's own compute charm." % model)

    offers = json.loads(run(["offers", "-m", ctl_model, "--format=json"]).stdout or "{}")
    print("\n-- consuming cross-model offers --")
    consumed = set()
    # ONLY the offers the DataMover actually has an endpoint for. The control
    # plane model exposes a dozen offers that belong to Sunbeam (nova,
    # ovn-relay, barbican, traefik-rgw...); consuming those would add SaaS
    # entries to the machine model that nothing binds to, which is the same
    # "install Trilio services only" rule the bundles now follow.
    for name in ("rabbitmq", "keystone-credentials", "cert-distributor"):
        detail = offers.get(name)
        url = detail.get("offer-url") if detail else None
        if not url:
            continue
        p = run(["consume", "-m", model, url, name], check=False)
        if p.returncode == 0:
            print("  consumed %s" % url)
        elif "already exists" in p.stderr or "saas" in p.stderr.lower():
            print("  ok      %s (already consumed)" % name)
        else:
            print("  ERROR   %s\n          %s" % (name, p.stderr.strip()))
            continue
        consumed.add(name)

    for required in ("rabbitmq", "keystone-credentials"):
        if required not in consumed:
            raise SystemExit(
                "no '%s' offer in %s. Run './deploy_trilio.py ctlplane' first."
                % (required, ctl_model))
    if "cert-distributor" not in consumed:
        print("  WARNING no cert-distributor offer -- on a TLS cloud the "
              "datamover's ca-bundle.pem is never written and Keystone TLS "
              "verification will fail.")

    deploy_bundle(model, DATAPLANE_BUNDLE, ["trilio-data-mover"])

    # Consumed offers are relation targets too, but they are SaaS entries, not
    # applications, so they never show up under "applications" in status.
    present = set(status(model).get("applications", {})) | consumed
    rc = 0
    print("\n-- relations --")
    for trilio_ep, app, ep in DATAPLANE_RELATIONS:
        rc |= not integrate(model, trilio_ep, app, ep, present)
    return rc


def main():
    # Bundle paths below are relative; juju rejects an absolute path outside
    # the working directory, so run from where the bundles live.
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what not in ("ctlplane", "dataplane", "all"):
        raise SystemExit(__doc__)

    ctl = resolve_model("openstack")
    rc = 0
    if what in ("ctlplane", "all"):
        rc |= do_ctlplane(ctl)
    if what in ("dataplane", "all"):
        rc |= do_dataplane(resolve_model("openstack-machines"), ctl)

    print("\n" + ("FAILED -- see errors above." if rc else "Done."))
    return rc


if __name__ == "__main__":
    sys.exit(main())
