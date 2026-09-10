#!/usr/bin/env python3
"""Deploy TrilioVault onto a Sunbeam Canonical OpenStack cloud.

    ./deploy_trilio.py ctlplane     # run in/against the "openstack" k8s model
    ./deploy_trilio.py dataplane    # run in/against the "openstack-machines" model
    ./deploy_trilio.py all          # both, in order

Options:
    --db-storage=<size>     volume size for trilio-mysql, per unit ("50G").
                            Defaults to the size the cloud gives its own
                            OpenStack database clusters.
    --db-storage-pool=<p>   juju storage pool for trilio-mysql, which is what
                            selects the kubernetes storage class. Defaults to
                            the pool those same clusters use. Create one with
                            juju create-storage-pool <p> kubernetes
                            storage-class=<storage class>.
    --force-new-database    deploy trilio-mysql even though retained storage
                            from a previous trilio-mysql was found. The new
                            cluster starts EMPTY; the old disks are left alone.
    --no-wait               do not wait for the applications to become active
    --timeout=<seconds>     how long to wait for active (default 1800)

TrilioVault brings its own database cluster (trilio-mysql, mysql-k8s). It does
not use Sunbeam's mysql, which exists only in "single" topology clouds and is
sized from a service list that does not include TrilioVault. Its storage pool
and volume size are copied from the cloud's own OpenStack database clusters
unless overridden with the options above, and its memory and connection limits
come from Sunbeam's own sizing formula.

Everything that touches one of Sunbeam's own applications -- the relations to
rabbitmq / keystone / traefik / openstack-hypervisor / microceph, and the
cross-model offers -- is done here with `juju integrate`, which adds a relation
WITHOUT reconciling the application's revision or scale. That is the whole
point: a bundle that names an existing application will try to move it to the
revision the bundle states, which is how TVAULT-7644 downgraded microceph on
the QA cloud.

Safe to re-run. Deploys, offers, consumes and relations are all skipped if they
already exist. Storage is never destroyed, reused or reformatted.
"""

import json
import math
import os
import subprocess
import sys
import time

CTLPLANE_BUNDLE = "trilio-ctlplane-bundle.yaml"
DATAPLANE_BUNDLE = "trilio-dataplane-bundle.yaml"

CTLPLANE_APPS = ["trilio-wlm-k8s", "trilio-dm-api-k8s"]
DATAPLANE_APPS = ["trilio-data-mover"]

MYSQL_APP = "trilio-mysql"
MYSQL_CHARM = "mysql-k8s"
MYSQL_CHANNEL = "8.0/stable"
MYSQL_BASE = "ubuntu@22.04"
MYSQL_STORAGE_NAME = "database"
MYSQL_STORAGE_FALLBACK = "20G"

DB_PROCESSES = {"trilio-wlm-k8s": 6, "trilio-dm-api-k8s": 3}
DB_MAX_POOL_SIZE = 2
DB_MB_PER_CONNECTION = 12
DB_OVERSIZE_FACTOR = 1.2
DB_BUFFER_MB = 600

DEFAULT_WAIT_TIMEOUT = 1800
WAIT_POLL_SECONDS = 20

CTLPLANE_RELATIONS = [
    ("trilio-wlm-k8s:amqp", "rabbitmq", "amqp", True),
    ("trilio-wlm-k8s:identity-service", "keystone", "identity-service", True),
    ("trilio-wlm-k8s:ingress-internal", "traefik", "ingress", False),
    ("trilio-wlm-k8s:ingress-public", "traefik-public", "ingress", False),
    # Without the CA, keystonemiddleware fails TLS verification against
    # Sunbeam's HTTPS Keystone and every API request returns 503.
    ("trilio-wlm-k8s:receive-ca-cert", "keystone", "send-ca-cert", True),
    ("trilio-dm-api-k8s:amqp", "rabbitmq", "amqp", True),
    ("trilio-dm-api-k8s:identity-service", "keystone", "identity-service", True),
    ("trilio-dm-api-k8s:ingress-internal", "traefik", "ingress", False),
    ("trilio-dm-api-k8s:ingress-public", "traefik-public", "ingress", False),
    ("trilio-dm-api-k8s:receive-ca-cert", "keystone", "send-ca-cert", True),
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
    ("trilio-data-mover:juju-info", "openstack-hypervisor", "juju-info", True),
    ("trilio-data-mover:amqp", "rabbitmq", "amqp", True),
    ("trilio-data-mover:identity-credentials",
     "keystone-credentials", "identity-credentials", True),
    ("trilio-data-mover:receive-ca-cert", "cert-distributor", "send-ca-cert", False),
    # Optional: a Sunbeam cloud on local/LVM storage has no microceph at all,
    # and the charm gates its [ceph] config off when no pools are granted.
    ("trilio-data-mover:ceph", "microceph", "ceph", False),
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


def applications(model):
    return status(model).get("applications", {})


def app_scale(present, app):
    a = present.get(app) or {}
    scale = a.get("scale")
    if isinstance(scale, int) and scale > 0:
        return scale
    return len(a.get("units") or {}) or 1


def mysql_resources(scale):
    connections = 0
    memory = 0
    for processes in DB_PROCESSES.values():
        needed = DB_MAX_POOL_SIZE * processes + 3
        connections += needed
        memory += needed * DB_MB_PER_CONNECTION
    return {
        "experimental-max-connections":
            int(math.floor(connections * scale * DB_OVERSIZE_FACTOR)),
        "profile-limit-memory":
            int(math.ceil(memory * scale * DB_OVERSIZE_FACTOR)) + DB_BUFFER_MB,
    }


def valid_storage_size(value):
    size = value.strip()
    if not size:
        return False
    if size[-1] in "MGTP":
        size = size[:-1]
    try:
        return float(size) > 0
    except ValueError:
        return False


def check_storage_pool(model, pool):
    pools = json.loads(run(["storage-pools", "-m", model,
                            "--format=json"]).stdout or "{}")
    if pool in pools:
        return
    raise SystemExit(
        "storage pool %r does not exist in %s. Available: %s"
        "\nCreate one bound to a kubernetes storage class with:"
        "\n  juju create-storage-pool %s kubernetes storage-class=<storage class>"
        % (pool, model, ", ".join(sorted(pools)) or "none", pool))


def cloud_database_storage(model):
    """The storage pool and volume size the cloud gives its own OpenStack
    database clusters -- the largest of them, so a 20G single-topology cloud
    and a 1G/10G multi-topology cloud are both followed instead of a number
    hardcoded here."""
    charms = {app: data.get("charm-name")
              for app, data in applications(model).items()}
    doc = json.loads(run(["storage", "-m", model, "--format=json"]).stdout or "{}")
    sizes = {}
    pools = {}
    for section in ("filesystems", "volumes"):
        for entry in (doc.get(section) or {}).values():
            instance = entry.get("storage")
            if instance and entry.get("size"):
                sizes[instance] = entry["size"]
                pools[instance] = entry.get("pool")
    largest = 0
    pool = None
    for instance, data in (doc.get("storage") or {}).items():
        if instance.split("/")[0] != MYSQL_STORAGE_NAME:
            continue
        units = (data.get("attachments") or {}).get("units") or {}
        if not any(charms.get(u.split("/")[0]) == MYSQL_CHARM for u in units):
            continue
        if sizes.get(instance, 0) > largest:
            largest = sizes[instance]
            pool = pools.get(instance)
    return pool, ("%dM" % largest if largest else None)


def mysql_storage_directive(model, pool=None, size=None):
    if pool:
        check_storage_pool(model, pool)
    cloud_pool, cloud_size = cloud_database_storage(model)
    pool = pool or cloud_pool
    size = size or cloud_size or MYSQL_STORAGE_FALLBACK
    if pool:
        return "%s,%s" % (pool, size)
    return size


def kube_cli():
    for base in (["kubectl"], ["k8s", "kubectl"], ["microk8s", "kubectl"]):
        for prefix in ([], ["sudo", "-n"]):
            try:
                p = subprocess.run(prefix + base + ["version", "--client=true"],
                                   capture_output=True, text=True)
            except OSError:
                continue
            if p.returncode == 0:
                return prefix + base
    return None


def retained_db_volumes(model):
    """PVCs left behind by a previous trilio-mysql, whichever way it was removed.

    Juju retains storage on `remove-application` unless --destroy-storage is
    given, and the k8s storage class reclaims with Delete, so these PVCs are
    the only copy of the old TrilioVault metadata. Returns None when the check
    could not be run rather than pretending there is nothing there.
    """
    cli = kube_cli()
    if cli is None:
        return None
    namespace = model.split("/")[-1]
    p = subprocess.run(cli + ["get", "pvc", "-n", namespace, "--no-headers",
                              "-o", "custom-columns=NAME:.metadata.name"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return sorted(n for n in p.stdout.split()
                  if MYSQL_APP in n and MYSQL_STORAGE_NAME in n)


def ensure_mysql(model, force_new, db_pool, db_size):
    print("\n-- TrilioVault database cluster --")
    present = applications(model)
    if MYSQL_APP in present:
        print("  ok      %s already deployed" % MYSQL_APP)
    else:
        volumes = retained_db_volumes(model)
        if volumes is None:
            print("  WARNING could not list PVCs in %s -- deploying %s without "
                  "checking for retained storage" % (model, MYSQL_APP))
        elif volumes and not force_new:
            raise SystemExit(
                "\nFAILED: retained database storage found in %s:\n"
                "  %s\n\n"
                "These volumes hold the TrilioVault metadata of a previous "
                "%s and are\nthe only copy of it -- the storage class reclaims "
                "with Delete.\nDeploying now would create an EMPTY cluster "
                "beside them.\n\n"
                "Restore that metadata into the new cluster from a dump, or "
                "re-run with\n--force-new-database to start empty. Nothing "
                "here deletes the volumes."
                % (model, "\n  ".join(volumes), MYSQL_APP))
        elif volumes:
            print("  note    keeping retained storage untouched: %s"
                  % ", ".join(volumes))
        scale = max(app_scale(present, a) for a in CTLPLANE_APPS)
        storage = mysql_storage_directive(model, db_pool, db_size)
        cmd = ["deploy", MYSQL_CHARM, MYSQL_APP, "-m", model,
               "--channel", MYSQL_CHANNEL, "--base", MYSQL_BASE, "--trust",
               "-n", str(scale),
               "--storage", "%s=%s" % (MYSQL_STORAGE_NAME, storage)]
        for key, value in sorted(mysql_resources(scale).items()):
            cmd += ["--config", "%s=%s" % (key, value)]
        run(cmd)
        print("  deployed %s (scale %d, storage %s)"
              % (MYSQL_APP, scale, storage))

    present = applications(model)
    rc = 0
    for app in CTLPLANE_APPS:
        rc |= not integrate(model, "%s:database" % app, MYSQL_APP, "database",
                            present, True)
    return rc


def integrate(model, trilio_ep, other_app, other_ep, present, required):
    label = "%s <-> %s:%s" % (trilio_ep, other_app, other_ep)
    if other_app not in present:
        if required:
            print("  ERROR   %s\n          %s is not in this cloud and this "
                  "relation is required" % (label, other_app))
            return False
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
    present = applications(model)
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


def wait_for_active(model, apps, timeout):
    print("\n-- waiting for %s to become active (timeout %ds) --"
          % (", ".join(apps), timeout))
    deadline = time.time() + timeout
    while True:
        present = applications(model)
        pending = []
        for app in apps:
            app_status = (present.get(app) or {}).get("application-status") or {}
            current = app_status.get("current")
            if current != "active":
                pending.append((app, current or "missing",
                                app_status.get("message", "")))
        if not pending:
            for app in apps:
                print("  active  %s" % app)
            return 0
        if time.time() >= deadline:
            print("\nFAILED: not active after %ds:" % timeout)
            for app, current, message in pending:
                print("  %-20s %-12s %s" % (app, current, message))
                units = (present.get(app) or {}).get("units") or {}
                for unit, data in sorted(units.items()):
                    workload = data.get("workload-status") or {}
                    print("    %-22s %-12s %s"
                          % (unit, workload.get("current", ""),
                             workload.get("message", "")))
            return 1
        for app, current, message in pending:
            print("  waiting %-20s %-12s %s" % (app, current, message))
        time.sleep(WAIT_POLL_SECONDS)


def do_ctlplane(model, force_new_database, db_pool, db_size):
    print("\n== Control plane -> %s ==" % model)
    deploy_bundle(model, CTLPLANE_BUNDLE, CTLPLANE_APPS, trust=True)

    rc = ensure_mysql(model, force_new_database, db_pool, db_size)

    present = applications(model)
    print("\n-- relations to Sunbeam's applications --")
    for trilio_ep, app, ep, required in CTLPLANE_RELATIONS:
        rc |= not integrate(model, trilio_ep, app, ep, present, required)

    print("\n-- offers for the data plane --")
    existing = json.loads(run(["offers", "-m", model, "--format=json"]).stdout or "{}")
    for app, ep, name in CTLPLANE_OFFERS:
        if name in existing:
            print("  ok      %s (already offered)" % name)
            continue
        if app not in present:
            print("  ERROR   %s cannot be offered (%s not in this cloud)"
                  % (name, app))
            rc |= 1
            continue
        # Bare owner/model here: a controller-qualified model inline is
        # rejected with 'user name ... not valid'.
        run(["offer", "%s.%s:%s" % (model, app, ep), name])
        print("  offered %s" % name)
    return rc


def do_dataplane(model, ctl_model):
    print("\n== Data plane -> %s ==" % model)
    present = applications(model)
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

    deploy_bundle(model, DATAPLANE_BUNDLE, DATAPLANE_APPS)

    # Consumed offers are relation targets too, but they are SaaS entries, not
    # applications, so they never show up under "applications" in status.
    present = set(applications(model)) | consumed
    rc = 0
    print("\n-- relations --")
    for trilio_ep, app, ep, required in DATAPLANE_RELATIONS:
        rc |= not integrate(model, trilio_ep, app, ep, present, required)
    return rc


def parse_args(argv):
    what = "all"
    force_new_database = False
    db_pool = None
    db_size = None
    wait = True
    timeout = DEFAULT_WAIT_TIMEOUT
    for arg in argv:
        if arg in ("ctlplane", "dataplane", "all"):
            what = arg
        elif arg.startswith("--db-storage="):
            db_size = arg.split("=", 1)[1].strip()
            if not valid_storage_size(db_size):
                raise SystemExit(
                    "--db-storage takes a volume size such as 50G, not %r"
                    % db_size)
        elif arg.startswith("--db-storage-pool="):
            db_pool = arg.split("=", 1)[1].strip()
            if not db_pool:
                raise SystemExit("--db-storage-pool takes a juju storage pool name")
        elif arg == "--force-new-database":
            force_new_database = True
        elif arg == "--no-wait":
            wait = False
        elif arg.startswith("--timeout="):
            try:
                timeout = int(arg.split("=", 1)[1])
            except ValueError:
                raise SystemExit(__doc__)
        else:
            raise SystemExit(__doc__)
    return what, force_new_database, db_pool, db_size, wait, timeout


def main():
    sys.stdout.reconfigure(line_buffering=True)

    # Bundle paths below are relative; juju rejects an absolute path outside
    # the working directory, so run from where the bundles live.
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    (what, force_new_database, db_pool, db_size,
     wait, timeout) = parse_args(sys.argv[1:])

    ctl = resolve_model("openstack")
    rc = 0
    if what in ("ctlplane", "all"):
        rc |= do_ctlplane(ctl, force_new_database, db_pool, db_size)
    if what in ("dataplane", "all"):
        rc |= do_dataplane(resolve_model("openstack-machines"), ctl)

    if rc:
        print("\nFAILED -- see errors above.")
        return rc
    if not wait:
        print("\nDeployed. Not waiting for active (--no-wait); check "
              "'juju status' yourself.")
        return 0

    if what in ("ctlplane", "all"):
        rc |= wait_for_active(ctl, CTLPLANE_APPS + [MYSQL_APP], timeout)
    if what in ("dataplane", "all"):
        rc |= wait_for_active(resolve_model("openstack-machines"),
                              DATAPLANE_APPS, timeout)

    print("\n" + ("FAILED -- see errors above." if rc else "Done."))
    return rc


if __name__ == "__main__":
    sys.exit(main())
