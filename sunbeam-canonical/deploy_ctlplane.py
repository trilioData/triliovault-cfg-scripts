#!/usr/bin/env python3
"""Deploy the TrilioVault control plane onto Sunbeam Canonical OpenStack.

    ./deploy_ctlplane.py [-m MODEL]

Installs Trilio services ONLY. Every other application this touches -- mysql,
rabbitmq, keystone, traefik, traefik-public -- already exists in a bootstrapped
Sunbeam cloud and is owned by Sunbeam. This script only ever adds RELATIONS to
them. `juju integrate` cannot refresh, rescale or otherwise alter an
application's desired state, which is precisely why the relations live here
instead of in the bundle (see the SCOPE note in trilio-ctlplane-bundle.yaml,
TVAULT-7404 and TVAULT-7644).

Safe to re-run: the bundle is skipped once every Trilio app is present, and each
relation is skipped if it already exists. It installs but never upgrades -- use
`juju refresh` for that.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from trilio_sunbeam import (  # noqa: E402
    DeployError, Juju, die, fail, ok, require_tools, skip, step,
)

BUNDLE = "trilio-ctlplane-bundle.yaml"
TRILIO_APPS = ["trilio-wlm-k8s", "trilio-dm-api-k8s"]

# Required: the Trilio charms cannot reach Active without these.
SUNBEAM_REQUIRED = ["mysql", "rabbitmq", "keystone"]

# Optional: ingress-internal / ingress-public are declared `optional: true` in
# both charmcraft.yaml files, and a Sunbeam cloud need not run a public ingress.
# Same rule as ceph and cert-distributor on the data plane -- if OpenStack does
# not have it, we do not require it.
SUNBEAM_OPTIONAL = ["traefik", "traefik-public"]


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "-m", "--model",
        default=os.environ.get("TRILIO_CTLPLANE_MODEL", "openstack"),
        help="k8s model to deploy into (default: openstack, or $TRILIO_CTLPLANE_MODEL). "
             "Accepts 'model', 'user/model' or 'controller:user/model'.",
    )
    return p.parse_args()


def main():
    args = parse_args()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    require_tools()
    juju = Juju(args.model)
    if not juju.resolve():
        raise DeployError(
            "model '" + args.model + "' not found. Pass the right one with -m, "
            "e.g. -m controller0/openstack."
        )
    # Sunbeam models are owner-qualified; resolve() expanded a bare short name so
    # every juju call below uses the form juju actually accepts.
    print("TrilioVault control plane -> model '" + juju.model + "'")

    # Checked BEFORE deploying: pointing at the wrong model must not leave
    # orphaned Trilio applications behind for the operator to clean up by hand.
    step("Checking Sunbeam services this deployment integrates with")
    missing = []
    for app in SUNBEAM_REQUIRED:
        if juju.app_exists(app):
            ok("found " + app)
        else:
            fail("missing " + app)
            missing.append(app)
    if missing:
        raise DeployError(
            "not found in model '" + juju.model + "': " + ", ".join(missing) + "\n"
            "These are Sunbeam's own services and must already be running -- this script\n"
            "does not install them. Check 'juju status -m " + juju.model + "', or point at\n"
            "the right model with -m. Nothing has been deployed."
        )

    available = set()
    for app in SUNBEAM_OPTIONAL:
        if juju.app_exists(app):
            ok("found " + app + " (optional)")
            available.add(app)
        else:
            skip(app + " not deployed -- that ingress will not be wired")

    # --trust is required: both charms patch their own StatefulSet via lightkube
    # (FUSE device access for s3vaultfuse). Without it Juju refuses the deploy.
    step("Deploying Trilio applications")
    juju.deploy_bundle(BUNDLE, TRILIO_APPS, ["--trust"])

    rc = 0

    step("Relating WLM to Sunbeam services")
    rc |= not juju.integrate("trilio-wlm-k8s:database", "mysql:database")
    rc |= not juju.integrate("trilio-wlm-k8s:amqp", "rabbitmq:amqp")
    rc |= not juju.integrate("trilio-wlm-k8s:identity-service", "keystone:identity-service")
    if "traefik" in available:
        rc |= not juju.integrate("trilio-wlm-k8s:ingress-internal", "traefik:ingress")
    if "traefik-public" in available:
        rc |= not juju.integrate("trilio-wlm-k8s:ingress-public", "traefik-public:ingress")

    step("Relating DataMover-API to Sunbeam services")
    rc |= not juju.integrate("trilio-dm-api-k8s:database", "mysql:database")
    rc |= not juju.integrate("trilio-dm-api-k8s:amqp", "rabbitmq:amqp")
    rc |= not juju.integrate("trilio-dm-api-k8s:identity-service", "keystone:identity-service")
    if "traefik" in available:
        rc |= not juju.integrate("trilio-dm-api-k8s:ingress-internal", "traefik:ingress")
    if "traefik-public" in available:
        rc |= not juju.integrate("trilio-dm-api-k8s:ingress-public", "traefik-public:ingress")

    # Also declared in the bundle, but the bundle is skipped once both apps
    # exist, so reconcile it here too -- otherwise this is the one relation a
    # re-run would never restore if it went missing, and dm-api would sit
    # waiting on wlm-service.
    step("Relating DataMover-API to WLM")
    rc |= not juju.integrate("trilio-dm-api-k8s:wlm-service", "trilio-wlm-k8s:wlm-service")

    # Same model as keystone, so this is unconditional -- matching upstream
    # Sunbeam, which gates the CA relation on a nullable offer URL only for
    # cross-model consumers. Without it keystonemiddleware fails TLS
    # verification against the Keystone HTTPS endpoint and every API call
    # returns 503.
    step("Distributing the Keystone CA certificate")
    rc |= not juju.integrate("trilio-wlm-k8s:receive-ca-cert", "keystone:send-ca-cert")
    rc |= not juju.integrate("trilio-dm-api-k8s:receive-ca-cert", "keystone:send-ca-cert")

    step("Done")
    if rc:
        fail("one or more steps failed -- see the errors above.")
        return 1

    m = juju.model
    print(
        "  Control plane deployed. Watch it settle with:\n"
        "    juju status -m " + m + " trilio-wlm-k8s trilio-dm-api-k8s\n"
        "    juju wait-for application -m " + m + " trilio-wlm-k8s"
        " --query='status==\"active\"' --timeout=10m\n"
        "    juju wait-for application -m " + m + " trilio-dm-api-k8s"
        " --query='status==\"active\"' --timeout=10m\n"
        "\n"
        "  Still to do by hand (see README.md):\n"
        "    - attach the Trilio Horizon plugin image to Sunbeam's horizon app\n"
        "    - create the cloud admin trust and apply the licence"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DeployError as exc:
        die(exc)
    except KeyboardInterrupt:
        die("interrupted", code=130)
