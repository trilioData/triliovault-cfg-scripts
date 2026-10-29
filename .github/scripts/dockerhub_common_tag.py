#!/usr/bin/env python3
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

HUB = "https://hub.docker.com"


def request(url, payload=None, token=None):
    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=60) as response:
        return json.load(response)


def login(username, secret):
    try:
        return request(f"{HUB}/v2/auth/token", {"identifier": username, "secret": secret})["access_token"]
    except (urllib.error.HTTPError, KeyError):
        return request(f"{HUB}/v2/users/login", {"username": username, "password": secret})["token"]


def tags(namespace, repository, token, contains):
    query = urllib.parse.urlencode({"page_size": 100, "name": contains[0]})
    url = f"{HUB}/v2/namespaces/{namespace}/repositories/{repository}/tags?{query}"
    found = {}
    while url:
        page = request(url, token=token)
        for tag in page.get("results") or []:
            name = tag.get("name", "")
            if all(part in name for part in contains):
                found[name] = tag.get("tag_last_pushed") or tag.get("last_updated") or ""
        url = page.get("next")
    return found


def main():
    parser = argparse.ArgumentParser(description="Find the newest tag present in every given Docker Hub repository.")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--repositories", required=True, nargs="+")
    parser.add_argument("--contains", required=True, nargs="+")
    args = parser.parse_args()

    username = os.environ.get("DOCKERHUB_USER", "")
    secret = os.environ.get("DOCKERHUB_TOKEN", "")
    if not username or not secret:
        print("DOCKERHUB_USER and DOCKERHUB_TOKEN must be set", file=sys.stderr)
        return 1
    try:
        token = login(username, secret)
    except urllib.error.URLError as error:
        print(f"Docker Hub login failed: {error}", file=sys.stderr)
        return 1

    common = None
    pushed = {}
    for repository in args.repositories:
        try:
            found = tags(args.namespace, repository, token, args.contains)
        except urllib.error.URLError as error:
            print(f"Cannot list tags of {args.namespace}/{repository}: {error}", file=sys.stderr)
            return 1
        print(f"{args.namespace}/{repository}: {len(found)} matching tags")
        common = set(found) if common is None else common & set(found)
        for name, when in found.items():
            pushed[name] = max(pushed.get(name, ""), when)

    if not common:
        print(f"No tag containing {' and '.join(args.contains)} exists in every repository", file=sys.stderr)
        return 1
    tag = max(common, key=lambda name: (pushed[name], name))
    print(f"Selected tag {tag}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"tag={tag}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
