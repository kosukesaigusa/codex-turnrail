"""Submit a signed app to Apple and verify the attached notarization ticket."""

import base64
import binascii
import hashlib
import json
import os
import stat
import subprocess
import tempfile
import uuid
from contextlib import contextmanager
from pathlib import Path

REPORT = "notarization-report.json"
SUBMISSION = "notarization-submission.json"
INPUT = "notarization-input.zip"
LOG = "notarization-log.json"


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def bundle_hash(app):
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        metadata = path.lstat()
        digest.update(path.relative_to(app).as_posix().encode() + b"\0")
        digest.update(str(stat.S_IMODE(metadata.st_mode)).encode() + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(b"file\0" + sha256(path).encode())
        elif path.is_dir():
            digest.update(b"directory")
        else:
            raise ValueError("The app contains an unsupported filesystem entry.")
        digest.update(b"\0")
    return digest.hexdigest()


def execute(arguments, *, timeout):
    try:
        return subprocess.run(
            arguments, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        raise ValueError(
            "Notarization command timed out; retain the submission ID."
        ) from None


def checked(arguments, *, timeout):
    result = execute(arguments, timeout=timeout)
    if result.returncode != 0:
        raise ValueError(f"{arguments[0]} failed with exit code {result.returncode}.")
    return result


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    temporary.replace(path)


@contextmanager
def credentials(environment):
    names = ("MACOS_NOTARY_KEY_ID", "MACOS_NOTARY_ISSUER_ID", "MACOS_NOTARY_KEY_BASE64")
    values = []
    for name in names:
        value = environment[name]
        if not isinstance(value, str) or not value or value != value.strip():
            raise ValueError(f"{name} must be explicitly configured.")
        values.append(value)
    key_id, issuer, encoded = values
    uuid.UUID(issuer)
    try:
        private_key = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("MACOS_NOTARY_KEY_BASE64 is invalid Base64.") from None
    if not private_key.startswith(b"-----BEGIN PRIVATE KEY-----"):
        raise ValueError("The notarization credential must be a PKCS#8 private key.")
    with tempfile.TemporaryDirectory(prefix="turnrail-notary-key-") as temporary:
        key = Path(temporary) / "AuthKey.p8"
        descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(private_key)
        yield ["--key", str(key), "--key-id", key_id, "--issuer", issuer]


def preflight(environment):
    with credentials(environment) as authentication:
        checked(
            [
                "xcrun",
                "notarytool",
                "history",
                *authentication,
                "--output-format",
                "json",
            ],
            timeout=60,
        )


def verify_ticket(app):
    checked(["xcrun", "stapler", "validate", str(app)], timeout=60)
    checked(
        ["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], timeout=60
    )


def verify_report(app, output):
    report = json.loads((output / REPORT).read_text())
    uuid.UUID(report["submission_id"])
    if (
        report["status"] != "Accepted"
        or report["stapled"] is not True
        or report["gatekeeper_accepted"] is not True
        or report["bundle_sha256"] != bundle_hash(app)
    ):
        raise ValueError("The app does not match a verified notarization report.")
    verify_ticket(app)
    return report


def notarize(app, output, environment):
    if (output / REPORT).exists():
        return verify_report(app, output)
    archive = output / INPUT
    submission_path = output / SUBMISSION
    with credentials(environment) as authentication:
        if submission_path.exists():
            submission = json.loads(submission_path.read_text())
            uuid.UUID(submission["id"])
            if submission["archive_sha256"] != sha256(archive) or submission[
                "bundle_sha256"
            ] != bundle_hash(app):
                raise ValueError(
                    "Saved notarization submission does not match this app."
                )
        else:
            if archive.exists():
                raise ValueError(
                    "An upload archive exists without a submission ID. "
                    "Check Apple submission history before sending another request."
                )
            checked(
                [
                    "ditto",
                    "-c",
                    "-k",
                    "--sequesterRsrc",
                    "--keepParent",
                    str(app),
                    str(archive),
                ],
                timeout=300,
            )
            response = checked(
                [
                    "xcrun",
                    "notarytool",
                    "submit",
                    str(archive),
                    *authentication,
                    "--output-format",
                    "json",
                ],
                timeout=600,
            )
            submission_id = json.loads(response.stdout)["id"]
            uuid.UUID(submission_id)
            submission = {
                "id": submission_id,
                "archive_sha256": sha256(archive),
                "bundle_sha256": bundle_hash(app),
            }
            write_json(submission_path, submission)
        submission_id = submission["id"]
        print(f"Notarization submission: {submission_id}", flush=True)
        result = execute(
            [
                "xcrun",
                "notarytool",
                "wait",
                submission_id,
                *authentication,
                "--timeout",
                "45m",
                "--output-format",
                "json",
            ],
            timeout=2760,
        )
        try:
            status = json.loads(result.stdout)["status"]
        except (ValueError, KeyError, TypeError):
            raise ValueError(
                f"No notarization result was returned for {submission_id}; "
                "retain its submission record."
            ) from None
        write_json(
            output / "notarization-status.json", {"id": submission_id, "status": status}
        )
        if status in ("Accepted", "Invalid", "Rejected"):
            checked(
                [
                    "xcrun",
                    "notarytool",
                    "log",
                    submission_id,
                    str(output / LOG),
                    *authentication,
                ],
                timeout=60,
            )
        if result.returncode != 0 or status != "Accepted":
            raise ValueError(
                f"Notarization {submission_id} is {status}; "
                "inspect the saved status and log."
            )
    checked(["xcrun", "stapler", "staple", str(app)], timeout=120)
    verify_ticket(app)
    report = {
        "submission_id": submission_id,
        "status": "Accepted",
        "submitted_archive_sha256": submission["archive_sha256"],
        "stapled": True,
        "gatekeeper_accepted": True,
        "bundle_sha256": bundle_hash(app),
    }
    write_json(output / REPORT, report)
    return report
