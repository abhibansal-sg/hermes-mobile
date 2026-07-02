#!/usr/bin/env python3
"""Auditable Linear GraphQL helper for the autonomous loop.

Reads the app-identity token from ~/.hermes/scripts/linear-app-token.sh so writes
appear as the beat actor (NOT Abhi). Usage:
    lin.py q '<graphql query>'                      # read
    lin.py m '<graphql mutation>' '<json-vars>'     # write (vars optional)
Prints JSON to stdout.
"""
import json
import subprocess
import sys
import urllib.request

TOKEN = subprocess.check_output(
    ["/Users/abbhinnav/.hermes/scripts/linear-app-token.sh"], text=True
).strip()


def call(query, variables=None):
    body = {"query": query}
    if variables:
        body["variables"] = variables
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


if __name__ == "__main__":
    mode = sys.argv[1]
    q = sys.argv[2]
    v = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    print(json.dumps(call(q, v), indent=2))
