#!/usr/bin/env python3
"""Observe official Codex releases and maintain one upstream tracking issue."""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

from project_metadata import ROOT, VERSION, read_upstream, version_tuple

APPCAST_URL = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ISSUE_TITLE = "Codex upstream updates"
ISSUE_MARKER = "<!-- turnrail-upstream-watch -->"


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


def fetch_appcast():
    with urllib.request.urlopen(APPCAST_URL, timeout=30) as response:
        data = response.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError("The Codex appcast exceeds the expected size limit.")
    return parse_appcast(data)


def parse_appcast(data):
    items = ET.fromstring(data).findall("./channel/item")
    releases = []
    for item in items:
        version = item.findtext(SPARKLE + "shortVersionString")
        build = item.findtext(SPARKLE + "version")
        version_tuple(version)
        if not isinstance(build, str) or re.fullmatch(r"[1-9][0-9]*", build) is None:
            raise ValueError("Appcast contains an invalid app build.")
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Appcast item has no archive enclosure.")
        url = enclosure.attrib["url"]
        expected = f"https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-{version}.zip"
        if url != expected:
            raise ValueError("Appcast archive does not match the expected macOS URL.")
        size = int(enclosure.attrib["length"])
        signature = enclosure.attrib[SPARKLE + "edSignature"]
        if size <= 0 or not signature:
            raise ValueError("Appcast archive is missing size or signature data.")
        releases.append({"version": version, "build": build, "url": url, "size": size})
    if not releases:
        raise ValueError("The Codex appcast contains no macOS releases.")
    builds = [release["build"] for release in releases]
    if len(builds) != len(set(builds)):
        raise ValueError("The Codex appcast contains duplicate builds.")
    return max(releases, key=lambda release: int(release["build"]))


def latest_cli():
    release = github("repos/openai/codex/releases/latest")
    tag = release["tag_name"]
    if (
        release["draft"] is not False
        or release["prerelease"] is not False
        or re.fullmatch(f"rust-v{VERSION}", tag) is None
    ):
        raise ValueError("GitHub did not return a stable Codex CLI release.")
    return {"tag": tag, "url": release["html_url"]}


def observe(metadata):
    result = {"supported": metadata, "app": None, "cli": None, "errors": {}}
    for name, operation in (("app", fetch_appcast), ("cli", latest_cli)):
        try:
            result[name] = operation()
        except (OSError, ValueError, KeyError, TypeError, ET.ParseError) as error:
            result["errors"][name] = str(error)
        except subprocess.CalledProcessError as error:
            result["errors"][name] = error.stderr.strip()
    return result


def app_candidate(observation):
    if observation["app"] is None:
        return False
    return int(observation["app"]["build"]) > int(
        observation["supported"]["app"]["build"]
    )


def report_body(observation):
    supported = observation["supported"]
    lines = [
        ISSUE_MARKER,
        "This issue tracks official Codex updates and monitoring failures.",
        "",
        f"Supported app: {supported['app']['version']} ({supported['app']['build']}).",
        f"Engine base: {supported['codex']['tag']}.",
        "",
    ]
    pending = bool(observation["errors"])
    if observation["app"] is not None:
        app = observation["app"]
        pending |= app_candidate(observation)
        lines.append(f"Latest app: [{app['version']} ({app['build']})]({APPCAST_URL}).")
    if observation["cli"] is not None:
        cli = observation["cli"]
        pending |= version_tuple(cli["tag"][6:]) > version_tuple(
            supported["codex"]["tag"][6:]
        )
        lines.append(f"Latest stable CLI: [{cli['tag']}]({cli['url']}).")
    for source, error in observation["errors"].items():
        lines.extend(["", f"{source} monitoring failed: {error}"])
    lines.extend(
        [
            "",
            "CLI releases alone do not change the Engine base. An app candidate must",
            "pass signature inspection and expose a matching public CLI source release",
            "before an update PR is prepared.",
            "Official UI verification is still required.",
        ]
    )
    return "\n".join(lines) + "\n", pending


def update_issue(repository, observation):
    body, pending = report_body(observation)
    issues = []
    page = 1
    while True:
        batch = github(f"repos/{repository}/issues?state=all&per_page=100&page={page}")
        issues.extend(
            issue
            for issue in batch
            if "pull_request" not in issue
            and issue["title"] == ISSUE_TITLE
            and isinstance(issue["body"], str)
            and issue["body"].startswith(ISSUE_MARKER)
        )
        if len(batch) < 100:
            break
        page += 1
    if len(issues) > 1:
        raise ValueError("Multiple upstream tracking issues exist; resolve them first.")
    if not issues:
        if pending:
            return github(
                f"repos/{repository}/issues",
                method="POST",
                payload={"title": ISSUE_TITLE, "body": body},
            )
        return None
    issue = issues[0]
    state = "open" if pending else "closed"
    if issue["body"] != body or issue["state"] != state:
        return github(
            f"repos/{repository}/issues/{issue['number']}",
            method="PATCH",
            payload={"body": body, "state": state},
        )
    return issue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    scan = commands.add_parser("scan")
    scan.add_argument("output", type=Path)
    report = commands.add_parser("report")
    report.add_argument("observation", type=Path)
    report.add_argument("--repository", required=True)
    args = parser.parse_args()
    try:
        if args.action == "scan":
            observation = observe(read_upstream(ROOT))
            args.output.write_text(json.dumps(observation, indent=2) + "\n")
            print(report_body(observation)[0])
            return 1 if observation["errors"] else 0
        issue = update_issue(args.repository, json.loads(args.observation.read_text()))
        if issue is not None:
            print(issue["html_url"])
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Upstream monitoring failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
