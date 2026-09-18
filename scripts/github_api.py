"""Call the GitHub API with the configured GitHub CLI identity."""

import json
import subprocess


def github(endpoint, *, method="GET", payload=None):
    command = ["gh", "api", "--method", method, endpoint]
    if payload is not None:
        command.extend(["--input", "-"])
    result = subprocess.run(
        command,
        input=None if payload is None else json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None
