# AGENTS.md

Guidance for coding agents (Claude Code, Codex, and others) working in this repository. Read
[README.md](README.md) for the layout and [docs/STATUS.md](docs/STATUS.md) for what works and what is next.

## Workflow

- **Commit straight to `main`** until the first stable release. Don't use feature branches or pull requests.
  Commit or push only when asked.
- Write the user-facing reply in the user's language (currently Chinese). Docs under `docs/` and
  `TODO.md` are in Chinese; code, comments, `README.md` and this file are in English.
- Record verified findings where they belong:
  - probe results go in `docs/ROADMAP.md` §5.1
  - the current state and the plan go in `docs/STATUS.md`
  - task checkboxes go in `TODO.md`

## Build and test

Requires macOS 27 and Xcode 27.

```sh
xcodegen generate                                   # after editing project.yml; never edit the .xcodeproj
cd Packages/ChatComputerKit && swift test           # unit tests: run after every change
scripts/test-mac.sh                                 # unit tests, Xcode build, host API checks, live scenarios
```

Before claiming a change works, run the layer that exercises it:

| Change touches | Run |
|---|---|
| Portable logic (BridgeProtocol, ChatCore, ModelProxy, Orchestrator) | `swift test` |
| The agent loop or a model client | `scripts/harness.sh live-loop --scenario notes|approval|injection` (needs `CC_API_KEY`) |
| The guest driver (`AgentCore`) | `scripts/harness.sh vm up --update-agent --input-test 3` |
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
   items are bound to the build that wrote them, so every other build prompts. Items 0.1.x left there move
   to the files on first read. For a sandboxed release, use the data-protection keychain, which needs a
   provisioning profile (without one, a Developer ID build gets -34018 on every call).
5. **The guest agent's signature matters.** Privacy grants in the guest belong to its signing identity.
   Release builds must use the same Developer ID. Replace the agent bundle; never overwrite it in place,
   or code signing kills the running binary.
6. **Guest input must look like hardware.** Shortcuts press and release modifier keys with device flag
   bits. Text is typed as real key presses where the US layout has the character. Out-of-process panels
   such as the save dialog drop anything else.
7. **The VM stop request doesn't shut down a macOS guest.** It only opens a dialog. Shut down through the
   agent (`GuestCommand.shutdown`) or `VirtualMachineController.shutDown`. Quitting the app suspends the VM
   (`AppModel.prepareToQuit`); to stop a running app from a script, send SIGTERM, never SIGKILL.

## Development switches

These are environment variables, unset in normal use. Launch with `open --env NAME=value build/release/ChatComputer.app`.

| Variable | Effect |
|---|---|
| `CC_GUEST_PASSWORD` | Known guest password on first boot (at least 4 characters) |
| `CC_AUTO_ONBOARD=1` | Run every setup step in turn |
| `CC_DEV_MODEL`, `CC_DEV_API_KEY` | Configure the model, e.g. `deepseek:openAI:deepseek-flash` |
| `CC_DEV_TASK` | Submit this task once the guest is ready |
| `CC_DEV_LOG` | Append runner updates to a file, for unattended runs |

To drive the app's own VM from `cc-harness`, quit the app and set
`CC_VM_BUNDLE="$HOME/Library/Application Support/ChatComputer/ChatComputer.vm"`; both read the bundle's `secrets.json`.
Only one process can run a VM bundle at a time (it is locked). Coding agents can also drive the running app with
`chatcomputer` (see README).

## Safety while operating the VM

- The guest is a disposable test machine, but treat its prompts carefully. Decline permission requests
  the task doesn't need.
- Never type real credentials into the guest. Only use the guest's own test password, from `secrets.json`.
- Releases are outward-facing. Publish to GitHub Releases only when the user asks.
