#!/usr/bin/env python3
"""Exercise a packaged runtime through the upstream SDK and a local mock model."""

import argparse
import json
import os
import shlex
import sys
import tempfile
import threading
from pathlib import Path


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def scenario(package, root, name, decision, report):
    from app_server_harness import (
        MockResponsesServer,
        ev_completed,
        ev_response_created,
        sse,
    )
    from openai_codex import CodexConfig
    from openai_codex.client import CodexClient

    root.mkdir()
    codex_home = root / "codex-home"
    codex_home.mkdir()
    workspace = root / "workspace"
    workspace.mkdir()
    marker = workspace / "approval-marker.txt"
    approvals = []
    notifications = []
    report.update(
        case=name, passed=False, approvals=approvals, notifications=notifications
    )
    environment = {
        **os.environ,
        "CODEX_HOME": str(codex_home),
        "CODEX_APP_SERVER_DISABLE_MANAGED_CONFIG": "1",
        "ZDOTDIR": str(root),
        "NO_PROXY": "127.0.0.1,localhost",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    if decision is None:
        requests = [
            {
                "cmd": "command -v rg && rg --version",
                "login": False,
                "yield_time_ms": 10000,
            },
            {
                "cmd": "printf '%s\\n' CODE_MODE_HOST_OK",
                "login": False,
                "yield_time_ms": 10000,
            },
        ]
        source = (
            "text({results:await Promise.all("
            + json.dumps(requests)
            + ".map(args=>tools.exec_command(args)))})"
        )
        policy = "never"
    else:
        request = {
            "cmd": "printf '%s' RUNTIME_APPROVED > " + shlex.quote(str(marker)),
            "login": False,
            "yield_time_ms": 10000,
            "sandbox_permissions": "require_escalated",
            "justification": "Verify approval for this isolated runtime marker.",
        }
        source = "text(await tools.exec_command(" + json.dumps(request) + "))"
        policy = "on-request"

    def approval_handler(method, params):
        require(
            method == "item/commandExecution/requestApproval",
            f"Unexpected approval: {method}",
        )
        require(decision is not None, "Unexpected approval in sandboxed execution")
        require(
            str(marker) in str(params), "Approval does not identify the isolated marker"
        )
        approvals.append({"method": method, "decision": decision, "params": params})
        return {"decision": decision}

    with MockResponsesServer() as server:
        (codex_home / "config.toml").write_text(f'''model = "mock-model"
model_provider = "package_smoke"
approval_policy = "{policy}"
cli_auth_credentials_store = "file"
sandbox_mode = "workspace-write"
suppress_unstable_features_warning = true

[features]
code_mode_only = true
code_mode_host = true
shell_zsh_fork = true
shell_snapshot = false
memories = false
apps = false
plugins = false

[analytics]
enabled = false

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"

[model_providers.package_smoke]
name = "package smoke"
base_url = "{server.url}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
''')
        call_id = "runtime-" + name
        server.enqueue_sse(
            sse(
                [
                    ev_response_created(call_id),
                    {
                        "type": "response.output_item.done",
                        "item": {
                            "type": "custom_tool_call",
                            "call_id": call_id,
                            "name": "exec",
                            "input": source,
                        },
                    },
                    ev_completed(call_id),
                ]
            )
        )
        final_text = "RUNTIME_" + name.upper() + "_DONE"
        server.enqueue_assistant_message(final_text, response_id=call_id + "-done")
        client = CodexClient(
            CodexConfig(
                codex_bin=str(package / "bin/codex"),
                cwd=str(workspace),
                env=environment,
            ),
            approval_handler=approval_handler,
        )
        timer = threading.Timer(60, client.close)
        timer.start()
        try:
            with client:
                client.initialize()
                thread = client.thread_start(
                    {
                        "cwd": str(workspace),
                        "model": "mock-model",
                        "approvalPolicy": policy,
                        "approvalsReviewer": "user",
                        "sandbox": "workspace-write",
                        "ephemeral": True,
                    }
                ).thread
                turn = client.turn_start(
                    thread.id, "Run the isolated runtime verification."
                ).turn
                while True:
                    notification = client.next_turn_notification(turn.id)
                    payload = notification.payload.model_dump(
                        mode="json", by_alias=True
                    )
                    notifications.append(
                        {"method": notification.method, "params": payload}
                    )
                    if notification.method == "turn/completed":
                        require(
                            payload["turn"]["status"] == "completed",
                            "Runtime turn did not complete",
                        )
                        break
        finally:
            timer.cancel()
            report["stderr"] = list(client._stderr_lines)

        tool_outputs = [
            item["output"]
            for request in server.requests()
            for item in request.input()
            if item.get("type") == "custom_tool_call_output"
            and item.get("call_id") == call_id
        ]
        report.update(
            tool_outputs=tool_outputs,
            model_requests=len(server.requests()),
            marker_exists=marker.exists(),
        )
        require(len(tool_outputs) == 1, "Expected one Code Mode tool result")
        require(
            final_text in json.dumps(notifications), "Expected final assistant message"
        )
        if decision is None:
            result_blocks = [
                block["text"]
                for block in tool_outputs[0]
                if block["type"] == "input_text" and block["text"].startswith("{")
            ]
            require(
                len(result_blocks) == 1,
                "Expected structured parallel execution results",
            )
            executions = json.loads(result_blocks[0])["results"]
            require(
                [item["exit_code"] for item in executions] == [0, 0],
                f"Parallel commands failed: {json.dumps(executions)}",
            )
            outputs = json.dumps(tool_outputs)
            require(
                str(package / "codex-path/rg") in outputs, "Bundled rg was not selected"
            )
            require(
                "ripgrep" in outputs and "CODE_MODE_HOST_OK" in outputs,
                "Missing command output",
            )
            commands = [
                item["params"]["item"]["command"]
                for item in notifications
                if item["method"] == "item/completed"
                and item["params"]["item"]["type"] == "commandExecution"
            ]
            require(len(commands) == 2, "Expected two command execution events")
            require(
                all(
                    str(package / "codex-resources/zsh/bin/zsh") in command
                    for command in commands
                ),
                "Bundled zsh was not selected",
            )
        else:
            require(len(approvals) == 1, "Expected exactly one approval")
            if decision == "accept":
                require(
                    marker.read_text() == "RUNTIME_APPROVED",
                    "Approved command did not write its marker",
                )
            else:
                require(not marker.exists(), "Declined command wrote its marker")
        report["passed"] = True
        print(f"Runtime verification passed: {name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_directory", type=Path)
    parser.add_argument("report_path", type=Path)
    args = parser.parse_args()
    engine_repository = Path(__file__).resolve().parents[2] / "engine"
    for path in (args.package_directory, args.report_path):
        if not path.is_absolute():
            parser.error(f"Path must be absolute: {path}")
    package = args.package_directory.resolve()
    for binary in (
        "bin/codex",
        "bin/codex-code-mode-host",
        "codex-path/rg",
        "codex-resources/zsh/bin/zsh",
    ):
        require(
            os.access(package / binary, os.X_OK),
            f"Runtime executable is missing: {binary}",
        )
    require((package / "codex-package.json").is_file(), "Runtime manifest is missing")
    # The SDK merges env into os.environ, so clear inherited routing before creating it.
    for key in tuple(os.environ):
        if key.startswith("CODEX_") or key in ("BASH_ENV", "ZDOTDIR"):
            del os.environ[key]
    sys.path[:0] = [
        str(engine_repository / "sdk/python/src"),
        str(engine_repository / "sdk/python/tests"),
    ]
    reports = []
    try:
        with tempfile.TemporaryDirectory(prefix="turnrail-runtime-") as temporary:
            for name, decision in (
                ("code_mode", None),
                ("approval_accept", "accept"),
                ("approval_decline", "decline"),
            ):
                report = {}
                reports.append(report)
                scenario(package, Path(temporary) / name, name, decision, report)
    finally:
        args.report_path.write_text(json.dumps(reports, indent=2) + "\n")


if __name__ == "__main__":
    main()
