#!/usr/bin/env python3
import argparse
import base64
import configparser
import subprocess
import sys
from pathlib import Path

PARAMS = ("rabbit_quorum_queue", "rabbit_transient_quorum_queue", "amqp_durable_queues")
TRUE_VALUES = {"true", "1", "yes", "on"}
FALSE_VALUES = {"false", "0", "no", "off", ""}
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "values_overrides" / "rabbitmq_queues.yaml"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Detect the RabbitMQ queue settings used by nova and write them to the "
                    "T4O values override rabbitmq_queues.yaml."
    )
    parser.add_argument("--namespace", default="openstack",
                        help="Namespace of the OpenStack nova deployment (default: openstack)")
    parser.add_argument("--secret", default="nova-etc",
                        help="Secret holding the nova configuration (default: nova-etc)")
    parser.add_argument("--key", default="nova-compute.conf",
                        help="Key of the nova configuration inside the secret (default: nova-compute.conf)")
    parser.add_argument("--nova-conf",
                        help="Read nova configuration from this local file instead of the Kubernetes secret")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT),
                        help=f"Values override file to write (default: {DEFAULT_OUTPUT})")
    return parser.parse_args()


def read_nova_conf_from_secret(namespace, secret, key):
    jsonpath = "{.data['" + key.replace(".", "\\.") + "']}"
    try:
        result = subprocess.run(
            ["kubectl", "-n", namespace, "get", "secret", secret, "-o", f"jsonpath={jsonpath}"],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError:
        sys.exit("ERROR: kubectl not found in PATH.")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"ERROR: failed to read secret {namespace}/{secret}: {exc.stderr.strip()}")
    encoded = result.stdout.strip()
    if not encoded:
        sys.exit(f"ERROR: key '{key}' not found or empty in secret {namespace}/{secret}.")
    return base64.b64decode(encoded).decode("utf-8")


def to_bool(name, value):
    normalized = value.strip().strip("\"'").lower()
    if normalized in TRUE_VALUES:
        return True
    if normalized in FALSE_VALUES:
        return False
    sys.exit(f"ERROR: unrecognised boolean value '{value}' for {name} in nova configuration.")


def detect_settings(nova_conf_text):
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.read_string(nova_conf_text)
    section = parser["oslo_messaging_rabbit"] if parser.has_section("oslo_messaging_rabbit") else {}
    return {name: to_bool(name, section.get(name, "false")) for name in PARAMS}


def write_override(path, settings):
    lines = ["conf:", "  triliovault:"]
    lines += [f"    {name}: {str(settings[name]).lower()}" for name in PARAMS]
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    if args.nova_conf:
        source = args.nova_conf
        nova_conf_text = Path(args.nova_conf).read_text(encoding="utf-8")
    else:
        source = f"secret {args.namespace}/{args.secret} ({args.key})"
        nova_conf_text = read_nova_conf_from_secret(args.namespace, args.secret, args.key)

    settings = detect_settings(nova_conf_text)
    print(f"RabbitMQ queue settings detected from nova configuration in {source}:")
    for name in PARAMS:
        print(f"  {name} = {str(settings[name]).lower()}")

    write_override(args.output, settings)
    print(f"Written to {args.output}")


if __name__ == "__main__":
    main()
