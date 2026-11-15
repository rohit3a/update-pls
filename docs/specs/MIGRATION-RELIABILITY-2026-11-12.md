# Portable installation and safe SSH host discovery

Status: proposed; specification only. Evidence: the 2026-11-12 migration, Update pls 0.5.2, source `06092b2`. P1 means a blocking or unsafe integration failure; P2 means diagnostic friction.

## UPD-MIG-01 — A copied app retains an unusable self-update source path (P1, reproduced configuration defect)

**Observed:** The copied application's `UpdatePlsSource` pointed to an absolute checkout path on the old Mac. That checkout did not exist on the new Mac. [SelfUpdate.source](../../Sources/UpdatePls/SelfUpdate.swift) therefore returned nil; its fallback opens GitHub rather than completing self-update. Ordinary local checks still worked.

**Reproduction:** Build from checkout A, copy the application to a clean account or computer without A, and request self-update.

**Required behavior:** Detect the missing checkout explicitly and offer a supported repair. A relocatable installation must either use verified release artifacts or let the user select/create a valid checkout. Validate origin, version/build compatibility, directory ownership, and build prerequisites before executing source. Never silently use an unrelated `.git` directory just because it occupies the old path.

**Acceptance:** A relocated app clearly reports whether self-update is ready and why. Repair preserves settings and update history, verifies the replacement, retains a recoverable prior app, and resumes the same action. An unavailable compiler, offline origin, dirty checkout, wrong origin, or failed build leaves the installed app usable with an actionable error. The supported installation docs cover migration as well as first build.

**Session workaround:** Cloned the official source on the new Mac, rebuilt using the existing build script, verified the app signature, retained the previous bundle, and installed the rebuilt bundle with the new local source path. No product source fix was made.

## UPD-MIG-02 — SSH aliases are not proof of general shell access (P1, source-confirmed integration risk)

**Observed:** The new SSH config contained two aliases created solely for ClipBubble. Their server-side authorized keys intentionally force the ClipBubble `--peer` command. Update pls discovers every concrete alias and would issue `uname -s` and shell probes through those connections. Those aliases were explicitly disabled in Update pls before a full scan.

**Evidence boundary:** We did not reproduce an updater consuming clipboard payloads. The incompatibility follows from the observed forced-command configuration and [SSH discovery/Runner.detectOS](../../Sources/UpdatePls/Machines.swift). Do not claim a data leak occurred.

**Required behavior:** Discover connections without automatically assuming permission/capability to run arbitrary probes. New aliases should be candidates requiring an explicit host-selection step. Provide a stable exclusion mechanism and explain “restricted service connection” separately from “offline.” A metadata-only, bounded shell-capability preflight may run after selection; it must not record arbitrary stdout from an incompatible protocol.

**Acceptance:**

- Fixtures include ordinary POSIX/Windows SSH, a ClipBubble-like forced binary protocol, SFTP-only access, wrong username, missing key, unknown host key, and changed host key.
- Unselected or excluded aliases are never contacted, including on startup, scheduled checks, and CLI `check`/`update all`.
- Restricted aliases cannot hang scans or feed binary/private service payloads into logs. Diagnostics identify the capability mismatch without exposing payloads.
- Repair never removes key restrictions, disables host validation, copies private keys, or silently creates broader remote access.
- Existing explicitly selected machines continue to work; migration to a safer discovery policy is documented.

**Session workaround:** Preserved existing configuration and excluded the two service-only aliases with `disabledHosts`. After restart, the app's own startup log showed `hosts: local` and a successful eight-tool check. The unrestricted `check` CLI also checked only the local Mac and exited successfully.

## UPD-MIG-03 — Diagnose menu-only operation without mistaking tooling failure for an app crash (P2, observed tooling limitation)

Computer-use selection of the menu-bar app timed out. The process was alive, the official `check local` CLI succeeded, and normal startup completed checks in roughly two seconds. This is **not** evidence of an updater deadlock. The CLI prevented a false “app broken” conclusion.

Add a documented metadata-only health command (prefer structured output) reporting app version, configured/disabled hosts, self-update readiness, last completed check, check-in-progress state, and errors. Make the ordinary app-open action expose a useful settings/status surface even when its menu icon is hidden. Verify accessible names and keyboard operation on supported macOS versions; diagnose the control-tool limitation before changing application internals.

**Acceptance:** A clean and a relocated installation are diagnosable without clicking an unexposed status icon. Explicit unknown host names and failed checks must not look like a successful empty check. Status never dumps environment variables, GitHub tokens, SSH key contents, or arbitrary remote stdout. CLI exit-code changes, if needed, are documented and tested.

## Validation and scope

Relevant code: [App/CLI](../../Sources/UpdatePls/App.swift), [AppModel](../../Sources/UpdatePls/AppModel.swift), [Machines](../../Sources/UpdatePls/Machines.swift), [Shell](../../Sources/UpdatePls/Shell.swift), [SelfUpdate](../../Sources/UpdatePls/SelfUpdate.swift), and [build script](../../scripts/build-app.sh).

The local installation repairs are complete; product changes remain open. Available updates are not themselves defects. Do not broaden this work into remote machine administration or mass software upgrades.
