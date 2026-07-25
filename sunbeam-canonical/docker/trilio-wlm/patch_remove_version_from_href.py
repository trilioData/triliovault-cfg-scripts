"""Patch workloadmgr/api/common.py's remove_version_from_href().

The stock function assumes the API version ("v1") is always the first URL
path segment (e.g. "/v1/<tenant>"), which holds for kolla/RHOSP (WLM exposed
directly on its own port, no path prefix) but not Sunbeam: Traefik ingress
routes all OpenStack services off shared host IPs by path prefix, so WLM's
registered endpoint is "/trilio-wlm/v1/<tenant>" — version is the second
segment. The unpatched function raises "href ... does not contain version"
on every self-referential href it builds during workload-create.

This patches it to find the version segment anywhere in the path instead of
assuming position 1.
"""

path = "/usr/lib/python3/dist-packages/workloadmgr/api/common.py"

old = '''    parsed_url = urllib.parse.urlsplit(href)
    url_parts = parsed_url.path.split("/", 2)

    # NOTE: this should match vX.X or vX
    expression = re.compile(r"^v([0-9]+|[0-9]+\\.[0-9]+)(/.*|$)")
    if expression.match(url_parts[1]):
        del url_parts[1]

    new_path = "/".join(url_parts)'''

new = '''    parsed_url = urllib.parse.urlsplit(href)
    url_parts = parsed_url.path.split("/")

    # NOTE: this should match vX.X or vX — search every segment (not just
    # index 1) since ingress path-prefixing can put the version anywhere.
    expression = re.compile(r"^v([0-9]+|[0-9]+\\.[0-9]+)$")
    for i, part in enumerate(url_parts):
        if expression.match(part):
            del url_parts[i]
            break

    new_path = "/".join(url_parts)'''

content = open(path).read()
assert old in content, "remove_version_from_href anchor not found — package version changed?"
open(path, "w").write(content.replace(old, new, 1))
print("patched remove_version_from_href")
