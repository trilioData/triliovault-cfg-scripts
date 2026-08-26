#!/usr/bin/env python3
"""Deploy the TrilioVault data plane (DataMover) onto Sunbeam Canonical OpenStack.

    ./deploy_dataplane.py [-m MODEL]

Installs Trilio services ONLY. openstack-hypervisor and microceph already exist
in a bootstrapped Sunbeam cloud and are owned by Sunbeam -- microceph in
particular is Sunbeam's storage layer, never ours to install. This script only
ever adds RELATIONS to them. `juju integrate` cannot refresh or rescale an
application, which is why the relations live here and not in the bundle: a
`microceph` entry pinned to one cloud's revision is what broke TVAULT-7644.

Cross-model offer URLs are read from the control-plane model rather than hardcoded
-- they embed your own controller/user and model and differ on every deployment.
Scoping the lookup to one model mirrors upstream Sunbeam, whose CLI takes these
URLs from the Terraform state of the plan that created them, so an offer can only
ever come from this cloud's own control plane.

Safe to re-run: the bundle is skipped once deployed, offers are skipped if
already consumed, and each relation is skipped if it already exists.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from trilio_sunbeam import (  # noqa: E402
    DeployError, Juju, die, fail, info, ok, require_tools, skip, step,
)

BUNDLE = "trilio-dataplane-bundle.yaml"
TRILIO_APPS = ["trilio-data-mover"]

# NOTE on the remediation commands below: `juju offer <app>:<endpoint>` names the
# offer after the APPLICATION unless you say otherwise. Both keystone offers
# would therefore be called "keystone", and the second would overwrite the
# first. The explicit trailing offer name is required, not cosmetic.
OFFER_HELP = {
    "rabbitmq":
        "juju offer <ctlplane-model>.rabbitmq:amqp rabbitmq",
    "keystone-credentials":
        "juju offer <ctlplane-model>.keystone:identity-credentials keystone-credentials",
    "cert-distributor":
        "juju offer <ctlplane-model>.keystone:send-ca-cert cert-distributor",
}


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "-m", "--model",
        default=os.environ.get("TRILIO_DATAPLANE_MODEL", "openstack-machines"),
        help="machine model to deploy into (default: openstack-machines, or "
             "$TRILIO_DATAPLANE_MODEL). Accepts 'model', 'user/model' or "
             "'controller:user/model'.",
    )
    # Offer names are unique per model, not per controller. These let the
    # operator name the exact offer when a controller hosts more than one cloud.
    p.add_argument(
        "--ctlplane-model",
        default=os.environ.get("TRILIO_CTLPLANE_MODEL", "openstack"),
        help="k8s model whose offers this data plane consumes (default: openstack, "
             "or $TRILIO_CTLPLANE_MODEL). Offers are looked up in this model only.",
    )
    p.add_argument("--rabbitmq-offer", metavar="URL",
                   help="explicit rabbitmq offer URL (default: discovered)")
    p.add_argument("--keystone-offer", metavar="URL",
                   help="explicit keystone-credentials offer URL (default: discovered)")
    p.add_argument("--cert-offer", metavar="URL",
                   help="explicit cert-distributor offer URL (default: discovered)")
    return p.parse_args()


def main():
    args = parse_args()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    require_tools()
    juju = Juju(args.model)
    if not juju.resolve():
        raise DeployError(
            "model '" + args.model + "' not found. Pass the right one with -m, "
            "e.g. -m admin/openstack-machines."
        )
    # Sunbeam models are owner-qualified; resolve() expanded a bare short name so
    # every juju call below uses the form juju actually accepts.
    print("TrilioVault data plane -> model '" + juju.model + "'")

    step("Checking the compute principal")
    if not juju.app_exists("openstack-hypervisor"):
        raise DeployError(
            "openstack-hypervisor not found in model '" + juju.model + "'.\n"
            "trilio-data-mover is a subordinate charm and cannot get a unit without it.\n"
            "This script does not install openstack-hypervisor -- it is Sunbeam's own\n"
            "compute charm. Check 'juju status -m " + juju.model + "', or point at the\n"
            "right model with -m. Nothing has been deployed."
        )
    ok("found openstack-hypervisor")

    # Looked up in the control-plane model ONLY, never controller-wide: offer
    # names are unique within a model, so a second Sunbeam cloud on the same
    # controller cannot be picked up by mistake. A failed query raises rather
    # than being read as "no such offer".
    ctl = args.ctlplane_model
    step("Reading offers from control-plane model '" + ctl + "'")
    rabbit_offer = juju.find_offer("rabbitmq", ctl, args.rabbitmq_offer)
    keystone_offer = juju.find_offer("keystone-credentials", ctl, args.keystone_offer)
    cert_offer = juju.find_offer("cert-distributor", ctl, args.cert_offer)

    for name, url in (("rabbitmq", rabbit_offer),
                      ("keystone-credentials", keystone_offer)):
        if not url:
            raise DeployError(
                "no '" + name + "' offer found. Create it with:\n\n"
                "    " + OFFER_HELP[name] + "\n\n"
                "then re-run. The trailing offer name matters -- without it the offer is\n"
                "named after the application and will not be found. Inspect what exists with:\n"
                "    juju offers -m " + ctl
            )
    ok("rabbitmq             " + rabbit_offer)
    ok("keystone-credentials " + keystone_offer)
    if cert_offer:
        ok("cert-distributor     " + cert_offer)
    else:
        skip("cert-distributor    not offered -- CA distribution will be skipped")
        info("on a TLS-enabled cloud this is wrong; create the offer in '" + ctl + "' with:")
        info("    " + OFFER_HELP["cert-distributor"])

    step("Deploying the Trilio DataMover")
    juju.deploy_bundle(BUNDLE, TRILIO_APPS)

    rc = 0

    step("Consuming cross-model offers")
    rc |= not juju.consume(rabbit_offer, "rabbitmq")
    rc |= not juju.consume(keystone_offer, "keystone-credentials")
    if cert_offer:
        rc |= not juju.consume(cert_offer, "cert-distributor")
    if rc:
        # Stop here rather than pressing on. Every relation below names one of
        # these SaaS aliases, so continuing would bury the real cause under a
        # cascade of "application not found" errors from integrate.
        fail("could not consume the cross-model offers -- not attempting relations.")
        return 1

    step("Relating the DataMover")
    # Subordinate binding to the compute principal -- without this the charm
    # never gets a unit on any compute node.
    rc |= not juju.integrate("trilio-data-mover:juju-info", "openstack-hypervisor:juju-info")
    rc |= not juju.integrate("trilio-data-mover:amqp", "rabbitmq:amqp")
    rc |= not juju.integrate("trilio-data-mover:identity-credentials",
                             "keystone-credentials:identity-credentials")

    # CONDITIONAL. Upstream Sunbeam treats cert-distributor as an optional offer
    # and gates every cross-model CA integration on it being non-null; all 27
    # upstream charms declare receive-ca-cert as optional and go Active without
    # it. Ours does too. When the offer IS present it matters: without the CA
    # bundle, tvault-contego's ca-bundle.pem is never written and TLS
    # verification against Keystone fails.
    skipped = []
    step("Distributing the CA certificate (if offered)")
    if cert_offer:
        rc |= not juju.integrate("trilio-data-mover:receive-ca-cert",
                                 "cert-distributor:send-ca-cert")
    else:
        skip("no cert-distributor offer -- nothing to do")
        skipped.append(
            "CA certificate distribution (no 'cert-distributor' offer in '" + ctl + "').\n"
            "      On a TLS-enabled cloud this is WRONG: tvault-contego never gets\n"
            "      ca-bundle.pem and TLS verification against Keystone will fail.\n"
            "      Create the offer and re-run:  " + OFFER_HELP["cert-distributor"])

    # CONDITIONAL. microceph may not exist at all: a Sunbeam cloud backed by
    # local/LVM storage is a valid configuration and Trilio must run there. The
    # charm declares ceph as optional, discovers whether Cinder/Nova actually
    # use Ceph, and gates its [libvirt]/[ceph] config off when no pools were
    # granted. If OpenStack does not use Ceph, neither do we.
    step("Relating to Ceph (if this cloud uses it)")
    if juju.app_exists("microceph"):
        rc |= not juju.integrate("trilio-data-mover:ceph", "microceph:ceph")
    else:
        skip("microceph not deployed -- DataMover will run without Ceph support")
        skipped.append(
            "Ceph support (no 'microceph' application in this model).\n"
            "      Expected on a cloud with local/LVM storage. If OpenStack does use\n"
            "      Ceph-backed Cinder, re-run this script once microceph is deployed.")

    step("Done")
    if rc:
        fail("one or more steps failed -- see the errors above.")
        return 1

    m = juju.model
    print(
        "  Data plane deployed. Watch it settle with:\n"
        "    juju status -m " + m + " trilio-data-mover\n"
        "    juju wait-for application -m " + m + " trilio-data-mover"
        " --query='status==\"active\"' --timeout=10m\n"
        "\n"
        "  A DataMover unit appears on every openstack-hypervisor machine, including\n"
        "  nodes that join later via 'sunbeam cluster join' -- no action needed for\n"
        "  new compute nodes."
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DeployError as exc:
        die(exc)
    except KeyboardInterrupt:
        die("interrupted", code=130)
