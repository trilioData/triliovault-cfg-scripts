"""Shared helpers for the TrilioVault Sunbeam deploy scripts.

Used by deploy_ctlplane.py and deploy_dataplane.py.

Two invariants this module exists to enforce, both of which proved treacherous
to express in shell:

1. A FAILED juju query is never reported as "absent". Every helper that queries
   the model raises JujuError if the query itself fails, so a wrong controller,
   an expired macaroon or a transient API error can never be silently
   reinterpreted as "this cloud has no Ceph / no TLS" and quietly skip a
   relation while the deploy still reports success.

2. Nothing here ever alters the desired state of an application Trilio does not
   own. Relations are added with `juju integrate`, which cannot refresh or
   rescale an application. See the SCOPE notes in the bundle files, and
   TVAULT-7404 / TVAULT-7644 for what happens when that rule is broken.

stdout and stderr of every juju call are captured SEPARATELY -- merging them
corrupts the JSON we parse, because juju writes non-fatal notices to stderr
while still exiting 0.
"""

import json
import os
import shutil
import subprocess
import sys

__all__ = [
    "DeployError", "JujuError", "Juju", "OFFER_FLAGS",
    "info", "ok", "skip", "fail", "step", "die", "require_tools",
]


class DeployError(Exception):
    """Something is wrong with the cloud, the arguments or the environment."""


class JujuError(DeployError):
    """A juju command failed. Never means 'the thing is absent'."""


# SaaS alias -> the argparse flag that overrides it. The alias and the flag are
# NOT the same string ("keystone-credentials" vs --keystone-offer), so error
# messages must look the flag up rather than deriving it, or they hand the
# operator an argument argparse rejects.
OFFER_FLAGS = {
    "rabbitmq": "--rabbitmq-offer",
    "keystone-credentials": "--keystone-offer",
    "cert-distributor": "--cert-offer",
}

_COLOR = sys.stdout.isatty()


def _c(code, text):
    return "\033[" + code + text + "\033[0m" if _COLOR else text


def info(msg):
    print("  " + str(msg))


def ok(msg):
    print("  " + _c("0;32m", "ok") + "      " + str(msg))


def skip(msg):
    print("  " + _c("0;33m", "skip") + "    " + str(msg))


def fail(msg):
    print("  " + _c("0;31m", "FAILED") + "  " + str(msg), file=sys.stderr)


def step(msg):
    print("\n==> " + str(msg))


def die(msg, code=1):
    print(_c("0;31m", "ERROR:") + " " + str(msg), file=sys.stderr)
    sys.exit(code)


def _same_offer(a, b):
    """True if two offer URLs name the same offer.

    The same offer is spelled more than one way: `juju status` records
    "<user>/<model>.<offer>" while operators often use the controller-qualified
    "<controller>:<user>/<model>.<offer>". A raw string compare would call those
    different and refuse a perfectly correct re-run.

    But do NOT simply discard the controller: two controllers can each host a
    "admin/openstack.rabbitmq", and treating those as the same offer would let a
    `--rabbitmq-offer othercontroller:...` silently match a local endpoint --
    reintroducing, one more level down, the cross-cloud mis-wiring this module
    scopes offer lookups by model to avoid. An omitted controller means "this
    one", so it is compatible with anything; two DIFFERENT named controllers are
    not.
    """
    def split(u):
        u = (u or "").strip()
        return u.split(":", 1) if ":" in u else [None, u]

    ctrl_a, path_a = split(a)
    ctrl_b, path_b = split(b)
    if path_a != path_b:
        return False
    return ctrl_a is None or ctrl_b is None or ctrl_a == ctrl_b


def require_tools():
    if shutil.which("juju") is None:
        raise DeployError("juju CLI not found in PATH.")


class Juju:
    """Thin, model-scoped wrapper around the juju CLI.

    `model` may be "openstack", "admin/openstack" or
    "sunbeam-controller:admin/openstack". The controller, when named, is passed
    explicitly to every command that needs one, so a run never silently targets
    whichever controller happens to be current.
    """

    def __init__(self, model):
        self.model = model
        if ":" in model:
            self.controller, self.model_name = model.split(":", 1)
        else:
            self.controller, self.model_name = None, model
        self._status = None
        self._offers = {}
        self._models = None

    # --- process plumbing -------------------------------------------------

    def _run(self, args, check=True):
        """Run a juju subcommand. stdout/stderr captured separately."""
        cmd = ["juju"] + list(args)
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if check and proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise JujuError(
                "`" + " ".join(cmd) + "` failed (exit "
                + str(proc.returncode) + "):\n" + detail
            )
        return proc

    def _run_json(self, args):
        proc = self._run(list(args) + ["--format=json"])
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise JujuError(
                "could not parse JSON from `juju " + " ".join(args) + "`: " + str(exc)
                + "\nstdout was:\n" + proc.stdout[:2000]
            ) from exc

    def _controller_args(self):
        return ["-c", self.controller] if self.controller else []

    # --- queries ----------------------------------------------------------

    def _model_names(self):
        """Full "owner/model" names on this controller. Cached."""
        if self._models is None:
            data = self._run_json(["models"] + self._controller_args())
            self._models = [m["name"] for m in data.get("models", []) if m.get("name")]
        return self._models

    def resolve_model_name(self, name):
        """Expand a model name to the fully-qualified "owner/model" juju needs.

        Sunbeam's models are owner-qualified, and a bare `-m openstack-machines`
        fails with `model ... not found` when the current user is not the owner
        -- juju resolves an unqualified name against the CURRENT user, not the
        model's owner. Validating a short name and then continuing to pass that
        short name around is therefore not enough: every later `-m` would fail.
        So resolve once, up front, and use the qualified form everywhere after.

        Returns None if no such model exists. Raises if a short name matches more
        than one model, rather than picking one.
        """
        if name in self._model_names():
            return name
        matches = [f for f in self._model_names() if f.split("/")[-1] == name]
        if not matches:
            return None
        if len(matches) > 1:
            raise DeployError(
                "model name '" + name + "' is ambiguous -- it matches:\n    "
                + "\n    ".join(matches)
                + "\n\nPass the fully-qualified 'owner/model' form with -m."
            )
        return matches[0]

    def resolve(self):
        """Resolve self.model to its qualified form in place.

        Returns False if the model does not exist. On success every subsequent
        juju call uses the qualified name, so a bare short name given on the
        command line works even when the current user does not own the model.
        """
        resolved = self.resolve_model_name(self.model_name)
        if resolved is None:
            return False
        self.model_name = resolved
        self.model = self.qualify(resolved)
        return True

    def status(self, refresh=False):
        """Full model status, fetched once and cached.

        Every app probe reads the same snapshot instead of issuing a fresh
        whole-model status call, which is slow on a cloud with many apps.
        """
        if self._status is None or refresh:
            self._status = self._run_json(["status", "-m", self.model])
        return self._status

    def app_exists(self, name, refresh=False):
        """True for real applications AND consumed SaaS endpoints.

        Raises rather than returning False if the query fails -- absence must
        mean absence.
        """
        st = self.status(refresh=refresh)
        if name in st.get("applications", {}):
            return True
        return name in st.get("application-endpoints", {})

    def qualify(self, model):
        """Prefix `model` with this instance's controller, when one was named."""
        if self.controller and ":" not in model:
            return self.controller + ":" + model
        return model

    def offers(self, model):
        """Offers defined IN `model`, as {offer-name: offer-url}. Cached.

        Scoped to a single model on purpose. This mirrors how upstream Sunbeam
        resolves the same URLs: its CLI reads them out of the Terraform state of
        the plan that created them (`get_tfhelper("openstack-plan").output()`),
        so a URL can only ever come from this cloud's own control plane.
        Upstream never searches for an offer by name -- `find-offers` appears
        nowhere in snap-openstack.

        Searching the whole controller with `juju find-offers` would reintroduce
        exactly the ambiguity upstream does not have: a second Sunbeam cloud, or
        a model left over from a re-bootstrap, exposes its own `rabbitmq` and
        `keystone-credentials`, and picking the wrong one wires the DataMover to
        another cloud's services with no error at any later step. Offer names are
        unique WITHIN a model, so scoping to the control-plane model makes that
        impossible rather than merely detectable.

        `juju offers` also has cleaner semantics than `find-offers`: an empty
        model returns {} with exit 0, so a non-zero exit is unambiguously a real
        failure and is raised.
        """
        resolved = self.resolve_model_name(model)
        if resolved is None:
            raise DeployError(
                "control-plane model '" + model + "' not found on this controller.\n"
                "Name it with --ctlplane-model (accepts 'model' or 'owner/model')."
            )
        target = self.qualify(resolved)
        if target not in self._offers:
            data = self._run_json(["offers", "-m", target])
            found = {}
            for name, meta in (data or {}).items():
                url = (meta or {}).get("offer-url")
                if not url:
                    # Do NOT drop it. An offer juju listed but whose URL we
                    # cannot read is a schema surprise, not an absent offer, and
                    # reporting it as absent would send the operator off to
                    # create a duplicate offer against a control plane that
                    # already has one. Same invariant as everywhere else here:
                    # if we cannot answer, we say so rather than guessing.
                    raise JujuError(
                        "`juju offers -m " + target + "` listed an offer named '"
                        + str(name) + "' with no readable 'offer-url' field.\n"
                        "Refusing to treat it as absent. Inspect the raw output with:\n"
                        "    juju offers -m " + target + " --format=json"
                    )
                found[name] = url
            self._offers[target] = found
        return self._offers[target]

    def find_offer(self, offer_name, model, override=None):
        """The offer's URL in `model`, or None if that model does not offer it."""
        if override:
            return override
        return self.offers(model).get(offer_name)

    # --- mutations --------------------------------------------------------

    def consume(self, url, alias):
        # Deliberately checks SaaS endpoints ONLY, not `applications`. A native
        # application that happens to share the alias (a leftover from an older
        # deploy, a hand-rolled test app) must not be mistaken for an
        # already-consumed offer: we would skip the consume and then relate the
        # DataMover to the wrong application, silently. Same class of silent
        # mis-wiring that find_offer()'s ambiguity check refuses to risk.
        endpoints = self.status().get("application-endpoints", {})
        if alias in endpoints:
            # An alias already in use is only safe to reuse if it points at the
            # SAME offer. A leftover from a previous cloud, a re-bootstrap, or a
            # hand-run `juju consume` of another controller's offer would
            # otherwise be silently adopted here, and the DataMover would be
            # related to a different cloud's RabbitMQ or Keystone with no error
            # at any later step. That is the mis-wiring offers() scopes by model
            # to avoid; it must not slip back in one layer down.
            existing = (endpoints[alias] or {}).get("url")
            if not existing:
                raise JujuError(
                    "SaaS endpoint '" + alias + "' exists in model '" + self.model
                    + "' but its offer URL cannot be read from juju status.\n"
                    "Refusing to assume it is the right one."
                )
            if _same_offer(existing, url):
                skip("saas " + alias + " already consumed (" + existing + ")")
                return True

            # Points somewhere else. Report, never auto-resolve -- and be careful
            # what we advise: in openstack-machines these aliases are normally
            # consumed by Sunbeam itself for openstack-hypervisor, so telling the
            # operator to `juju remove-saas` could tear out a relation Sunbeam
            # owns. That is the very invariant this change exists to protect.
            others = sorted(
                app
                for apps in ((endpoints[alias] or {}).get("relations") or {}).values()
                for app in (apps or [])
                if not str(app).startswith("trilio-")
            )
            msg = ("SaaS endpoint '" + alias + "' already exists but points elsewhere:\n"
                   "      existing: " + existing + "\n"
                   "      wanted:   " + url + "\n")
            if others:
                msg += ("    It is in use by non-Trilio application(s): " + ", ".join(others) + ".\n"
                        "    Do NOT remove it -- that would break Sunbeam's own integrations.\n"
                        "    Point this deploy at the control plane that endpoint belongs to with\n"
                        "    --ctlplane-model, or name the offer explicitly with "
                        + OFFER_FLAGS.get(alias, "--<offer>-offer") + ".")
            else:
                msg += ("    Nothing else is using it. Either re-point this deploy with\n"
                        "    --ctlplane-model, or remove the stale endpoint and re-run:\n"
                        "        juju remove-saas -m " + self.model + " " + alias)
            fail(msg)
            return False
        if alias in self.status().get("applications", {}):
            fail("cannot consume " + url + " as '" + alias + "': a native application of "
                 "that name already exists in this model")
            return False
        proc = self._run(["consume", "-m", self.model, url, alias], check=False)
        if proc.returncode == 0:
            ok("consumed " + url + " as " + alias)
            self._status = None          # a new SaaS endpoint now exists
            return True
        fail("consume " + url + " as " + alias)
        print((proc.stderr or proc.stdout).strip(), file=sys.stderr)
        return False

    def integrate(self, a, b):
        """Add a relation, tolerating one that already exists so the deploy
        scripts can be re-run to repair a partial install."""
        proc = self._run(["integrate", "-m", self.model, a, b], check=False)
        if proc.returncode == 0:
            ok(a + " <-> " + b)
            return True
        err = (proc.stderr or proc.stdout).strip()
        if "already exists" in err.lower():
            skip(a + " <-> " + b + " (already related)")
            return True
        fail(a + " <-> " + b)
        print(err, file=sys.stderr)
        return False

    def deploy_bundle(self, bundle, apps, extra_args=()):
        """Deploy `bundle` unless every application it declares already exists.

        A PARTIAL deployment is completed by re-applying the bundle, so that a
        re-run never fails a deployment that just needs finishing. Be aware of
        what that costs: `juju deploy <bundle>` is a desired-state operation, so
        the applications already present are reconciled to the revision and
        image pinned in the bundle. That is a refresh of an application Trilio
        OWNS -- never a Sunbeam one -- so it cannot repeat TVAULT-7404, but it
        can move your own Trilio app onto the bundle's pins. The
        fully-deployed case skips entirely for that reason: these scripts
        install, they do not upgrade.
        """
        extra_args = list(extra_args)
        if not os.path.isfile(bundle):
            raise DeployError("bundle file not found: " + bundle)

        missing = [a for a in apps if not self.app_exists(a)]
        if not missing:
            skip("already deployed (" + ", ".join(apps) + ") -- not re-deploying " + bundle)
            info("these scripts install but never upgrade; to change revision or image use: "
                 "juju refresh -m " + self.model + " <app> ...")
            return True

        if len(missing) < len(apps):
            present = [a for a in apps if a not in missing]
            # Re-apply to complete the install. A re-run must never fail the
            # deployment, so we do NOT stop here -- but be explicit about the
            # cost: `juju deploy <bundle>` is a desired-state operation, so the
            # applications that are already present get reconciled to the
            # revision and image pinned in the bundle. That is a refresh of an
            # app Trilio owns (never a Sunbeam one), which is acceptable; it is
            # also why the fully-deployed case above skips instead.
            info("partial deployment -- present: " + ", ".join(present))
            info("                     missing: " + ", ".join(missing))
            info("re-applying " + bundle + " to complete it; this reconciles "
                 + ", ".join(present) + " to the bundle's pinned revision/image")

        info(("juju deploy ./" + bundle + " -m " + self.model + " " + " ".join(extra_args)).rstrip())
        proc = self._run(["deploy", "./" + bundle, "-m", self.model] + extra_args, check=False)
        combined = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode == 0:
            # juju writes its progress and summary ("Located charm ... in
            # charm-hub, channel ...", "Deploy of bundle completed.") to STDERR,
            # so printing only stdout would report success with no record of the
            # revisions and resources Juju actually resolved.
            if combined.strip():
                print(combined.rstrip())
            ok("deployed " + bundle)
            self._status = None
            return True

        print(combined.strip(), file=sys.stderr)
        if "downgrades are not currently supported" in combined.lower():
            raise DeployError(
                "bundle deploy failed: an application already in the model is running a NEWER\n"
                "revision than " + bundle + " pins, and Juju will not downgrade it.\n\n"
                "This happens when an app was 'juju refresh'ed past the pinned revision. The\n"
                "bundle is not an upgrade path. Either align the pin in " + bundle + " with what\n"
                "is deployed ('juju status -m " + self.model + "' shows current revisions), or\n"
                "deploy the missing app directly."
            )
        raise DeployError("bundle deploy failed: " + bundle)
