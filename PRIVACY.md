# Privacy and safety

Chat Computer runs a macOS virtual machine (the "virtual Mac") on your Mac, and an AI model operates it. This page
says what goes where. It describes version 0.9 and later.

## What leaves your Mac

- **To the model provider you choose** (Anthropic, OpenAI, DeepSeek, …): your task text, your answers in the chat,
  screenshots of the virtual Mac, and the agent's own notes and actions. This is how the model sees what it is doing.
  The provider's own privacy terms apply to that data.
- **Nothing else.** Chat Computer has no account, no analytics and no telemetry. It contacts Apple once during setup
  to download macOS, and GitHub only when you open a link.

## What stays on your Mac

Everything below is kept in one data folder: `~/.chatcomputer`, or the folder you chose during setup (Settings ›
Privacy & Data shows it). The folder is readable only by your user.

- **API keys** are stored in the data folder's `credentials.json`, readable only by your
  user (mode 0600). They are sent only to the provider they belong to, in the request header. They never enter the
  virtual Mac, the prompt, the logs or the diagnostics archive.
- **The virtual Mac's password** is stored in its bundle (`ChatComputer.vm/secrets.json`, mode 0600). The app types it
  into the virtual Mac from the host when a permission or the lock screen asks for it; the model never sees it.
- **Tasks and chats** are stored in the data folder's `Tasks` and `session.json`.
- **Diagnostics** (Help › Export Diagnostics) are written to your Desktop and sent nowhere. Stored secrets are removed
  from them; the task logs in them do contain your chat with the agent, so read them before you share them.

## What the virtual Mac can reach

- **Your files:** only what you give it. Files you attach to a task are copied into a read-only `inbox`; results come
  back through the `outbox`. Folders you share are read-only unless you allow writing, and system folders, your whole
  home folder, `~/Library` and hidden folders cannot be shared.
- **Your apps and screen:** nothing. It is a separate computer; the agent can only see and operate the virtual Mac's
  own screen.
- **The app:** a private virtual socket (vsock) that only this virtual machine can reach, protected by a pairing
  token. Input from the agent is accepted only while the agent holds control; clicking the virtual Mac takes control
  back at once.
- **The network:** the virtual Mac has internet access through your Mac (NAT), like any other virtual machine.
  Measured on macOS 27: it can reach services on your Mac that listen on all network interfaces (through
  `192.168.64.1` or your Mac's network address), but not services bound only to `127.0.0.1`. Other devices on your
  local network are likely reachable the same way. If you run development servers on all interfaces, the agent in the
  virtual Mac can reach them.

## Safety rules the model cannot change

The host, not the model, enforces the task's phase, who controls the input, the step and token budgets, and whether a
result counts as delivered (the files named in the result must exist). Before anything irreversible outside the
virtual Mac (sending, posting, paying, deleting, installing), the agent must stop and ask you. Text on screen and in
files is treated as data, not instructions; the regression set includes a planted instruction the agent must ignore
and report.

## Licence

macOS's licence allows virtual machines on Apple hardware only for certain purposes, among them software
development, testing and personal non-commercial use. Chat Computer is meant for those uses; check Apple's licence
before using it for anything else.
