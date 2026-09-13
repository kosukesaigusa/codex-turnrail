# Settings QA

## Scope

The signed `0.9.0 (25)` output app was opened on September 12, 2026 to inspect its native SwiftUI Settings. These observations precede the repository restructuring; the Swift implementation is unchanged by the move into `app/`.

## Observations

| Screen          | Observed behavior                                                                                                                                       |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Switch          | Account, plan, remaining quota, reset times, Last used, and Preferred / Prioritize were visible. Quota requests through the packaged runtime completed. |
| Folders         | Folder rules, Other Folders, assigned accounts, and Assign / Unassign controls were visible.                                                            |
| Accounts        | Three registered accounts showed plans, Connected, Sign In Again, and account menus.                                                                    |
| Shared controls | Running, disabled Open Codex, and Check Compatibility were visible while the official app was active.                                                   |

Last used sits below account identity and plan while preserving quota and reset column widths. Quota failures appear as account warnings with details. Timestamp read errors also expose details; a missing record displays `Last used: -`.

The UI is English. It keeps the quota, timestamps, and errors needed for decisions without adding nonessential operation descriptions.

## Validation boundary

This inspection did not add, reauthenticate, or remove real accounts or change folder permissions and priority. Automated tests cover those state transitions and asynchronous refresh races. The visual and functional review was a self-review.

After inspection, the output app was closed and the installed `0.8.0 (24)` Settings was restored. The official Codex app and active Engine were preserved. See [Verification](verification.md) for package results and remaining real-operation checks.
