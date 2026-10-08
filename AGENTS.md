# AGENTS.md

Guidance for coding agents (Claude Code, Codex, and others) working in this repository. Read
[README.md](README.md) for the layout and [docs/STATUS.md](docs/STATUS.md) for what works and what is next.

The repository is public. The current release is 0.9.9, a 1.0 candidate: features are frozen until 1.0, so
prefer fixing, testing and documenting over adding capabilities.

## Workflow

- **Commit straight to `main`** until the first stable release. Don't use feature branches or pull requests.
  Commit or push only when asked.
- Write the user-facing reply in the user's language (currently Chinese). Docs under `docs/` and
  `TODO.md` are in Chinese; code, comments, `README.md` and this file are in English.
- Record verified findings where they belong:
  - probe results go in `docs/ROADMAP.md` §5.1
  - the current state and the plan go in `docs/STATUS.md`
  - task checkboxes go in `TODO.md`
  - regression results go in `scripts/regress/results/` (JSONL, one file per run set)
- Related repositories: the website is `chatcomputer/chatcomputer.github.io` (static; regenerate its
  `results.json` with `scripts/regress/site-results.py`), the Homebrew cask is `chatcomputer/homebrew-tap`
  (`scripts/update-cask.sh`), and organisation-wide issue templates and policies live in `chatcomputer/.github`.

## Build and test

Requires macOS 27 and Xcode 27.

```sh
xcodegen generate                                   # after editing project.yml; never edit the .xcodeproj
cd Packages/ChatComputerKit && swift test           # unit tests: run after every change
scripts/test-mac.sh                                 # unit tests, Xcode build, host API checks, live scenarios
```

Don't build the Swift package while `cc-harness` is running a VM: the build relinks the binary in place and
code signing kills the running process. Use `xcodebuild` (its own derived data) or wait.

Before claiming a change works, run the layer that exercises it:

| Change touches | Run |
|---|---|
| Portable logic (BridgeProtocol, ChatCore, ModelProxy, Orchestrator) | `swift test` |
| The agent loop or a model client | `scripts/harness.sh live-loop --scenario notes|approval|injection` (needs `CC_API_KEY`) |
| The guest driver (`AgentCore`) | `scripts/harness.sh vm up --update-agent --input-test 3` |
| Agent behaviour, prompts, cost | `scripts/harness.sh vm regress` (built-in agent) and `scripts/regress/external.py` (Claude Code), before and after; add `--suite long` for multi-step, multi-app work (`tasks-long.json`) |
| The guest agent's version or driver, for regression | `vm regress --rebuild-base --agent <ChatComputerAgent.app>`: the base snapshot keeps the agent it was made with |
| Lifecycle: quit, sleep, snapshots, long runs | `scripts/soak.py`; a release's install path: `scripts/fresh-install.sh` |
| Apps, onboarding, signing | `scripts/release.sh`, then launch `build/release/ChatComputer.app` |

## Rules that are easy to break

1. **XcodeGen owns `Info.plist` and `.entitlements`.** Change properties, the version and entitlements in
   `project.yml`, never in the generated files: `xcodegen generate` overwrites them.
   The host app needs `com.apple.security.virtualization`.
2. **The model is never trusted with policy.** Task phase, the input lease, budgets and output
   verification are enforced in `AgentRunner` and in the guest, not by prompting. Completion requires the
   files listed in `report_result` to exist in the outbox.
3. **Model history is append-only.** Assistant content goes back unchanged, including thinking blocks and
   vendor fields such as `reasoning_content` and Gemini's `extra_content`. Don't rewrite earlier turns for
   Claude. Screenshot trimming applies only to non-Claude endpoints.
4. **Secrets stay on the host, in 0600 files** (`HostSecretStore`): the guest password and pairing token in
   the VM bundle's `secrets.json`, API keys in `~/Library/Application Support/ChatComputer/credentials.json`.
   Never log them, print them, put them in a URL, or commit them. Don't go back to the login Keychain: its
   items are bound to the build that wrote them, so every other build prompts. For a sandboxed release, use the data-protection keychain, which needs a
   provisioning profile (without one, a Developer ID build gets -34018 on every call).
5. **The guest agent's signature matters.** Privacy grants in the guest belong to its signing identity.
   Release builds must use the same Developer ID. Replace the agent bundle; never overwrite it in place,
   or code signing kills the running binary.
6. **Guest input must look like hardware.** Shortcuts press and release modifier keys with device flag
   bits. Text is typed as real key presses where the US layout has the character. Every key event keeps the
   bits a real keyboard sets (`NativeDriver.preservedFlagBits`, including NX_NONCOALESCED): without them,
   out-of-process panels such as the save dialog and Spotlight drop typing after any Cmd or Ctrl shortcut.
7. **The guest agent updates itself from the app.** On connect the app compares the agent's version
   ("0.9.0 (24)", with the build number) to the one it bundles and, when the guest is idle, replaces it through
   the bootstrap share. Snapshots keep the agent they were taken with, so restoring an old one updates it again.
   Bump `CURRENT_PROJECT_VERSION` for every build you put in a guest.
8. **A shared folder caches names in the guest.** A file or folder deleted and recreated on the host under the
   same name reads as stale or missing in a running guest. Give new content a new name (`AgentStaging` stages
   each agent update in its own folder) or delete-then-create each file; never rename over an existing one.
9. **The guest's clock lags after a snapshot restore.** Files it writes carry that time; compare files by
   fingerprint, not modification time (`SaveDialog.fingerprints`).
10. **The main window is AppKit; the rest is SwiftUI.** `MainWindowController` owns the window, its toolbar and
    its aspect-ratio resizing; the chat transcript is a ListViewKit `ListView` whose rows (`ChatRows.swift`)
    render agent messages with MarkdownView. A row's `height` closure and its `layout()` must agree exactly, or rows
    overlap. AppKit views follow `AppModel` through `Observing`. The window's content is always
    `WorkspaceViewController`: one `GuestStageView` on the left, and on the right the setup panel until the guest is
    ready, then the chat. The setup panel, Settings, the sheets and the error alert stay SwiftUI (`SceneBridge` hosts
    the sheets and alert inside the AppKit window).
11. **macOS 26 guests are set up by walking Setup Assistant.** macOS 26 ignores `VZMacGuestProvisioningOptions`, so
    `HostControl.SetupAssistant` reads each page (Vision) and clicks through it, then turns on SSH and automatic login
    from Terminal (`systemsetup` needs Full Disk Access there; `launchctl` doesn't). Page recognition is tested against
    text from real screens in `Tests/HostControlTests/SetupAssistantScreens`; when Apple changes a page, add its
    fixture (`cc-harness vm up --setup-assistant DIR` saves every screen it reads). The guest agent is built for
    macOS 26 from `Packages/ChatComputerAgentKit`: Launch Services refuses a binary built for a newer macOS
    (-10825), and then the agent never shows in Privacy settings. Keep 27-only APIs out of that package.
12. **The VM stop request doesn't shut down a macOS guest.** It only opens a dialog. Shut down through the
   agent (`GuestCommand.shutdown`) or `VirtualMachineController.shutDown`. Quitting the app suspends the VM
   (`AppModel.prepareToQuit`); to stop a running app from a script, send SIGTERM, never SIGKILL.

## Development switches

These are environment variables, unset in normal use. Launch with `open --env NAME=value build/release/ChatComputer.app`.

| Variable | Effect |
|---|---|
| `CC_GUEST_PASSWORD` | Known guest password on first boot (at least 4 characters) |
| `CC_AUTO_ONBOARD=1` | Run every setup step in turn |
| `CC_GUEST_MACOS=26` | Choose macOS 26 for the virtual Mac during setup (default 27) |
| `CC_RESTORE_IMAGE` | Install the virtual Mac from this local `.ipsw` instead of downloading one |
| `CC_DEV_MODEL`, `CC_DEV_API_KEY` | Configure the model, e.g. `deepseek:openAI:deepseek-flash` |
| `CC_DEV_TASK` | Submit this task once the guest is ready |
| `CC_DEV_LOG` | Append runner updates to a file, for unattended runs |
| `CC_DEV_CONTINUE=1` | Continue a task restored from the last session once the guest is ready |
| `CC_DEV_WINDOW_SHOTS=1` | Accept `dev_ui` and `dev_window_shot` on the control socket, to drive and capture the app's UI for docs and tests (`dev_ui` actions include `submit`, `cancel`, `continue`, `hostSleep`, `hostWake`, `diagnostics`, `snapshots`, `settings`, `appendChat` for test transcript content, `appearance` light/dark) |

To drive the app's own VM from `cc-harness`, quit the app and set
`CC_VM_BUNDLE="$HOME/Library/Application Support/ChatComputer/ChatComputer.vm"`; both read the bundle's `secrets.json`.
Only one process can run a VM bundle at a time (it is locked). Coding agents can also drive the running app with
`chatcomputer` (see README).

## Safety while operating the VM

- The guest is a disposable test machine, but treat its prompts carefully. Decline permission requests
  the task doesn't need.
- Never type real credentials into the guest. Only use the guest's own test password, from `secrets.json`.
- Before taking screenshots for docs or the website, clear the guest's notifications and permission prompts,
  and don't show the user's own snapshots or files.
- Releases are outward-facing. Publish to GitHub Releases only when the user asks. A release is
  `scripts/release.sh` (notarized), a `vX.Y.Z` tag, `gh release create` with English notes and the zip's SHA-256,
  then `scripts/update-cask.sh X.Y.Z` for the Homebrew cask in `chatcomputer/homebrew-tap`.
