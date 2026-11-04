# Permission fixtures

- `accessibility-26.png`: existing macOS 26.6.2 Accessibility pane fixture, captured at 2x.
- `screen-capture-consent-27.png`: macOS 27.0.1 (26A434), Chat Computer 0.9.12 (48),
  captured on 2026-11-03 during a fresh disposable VM's automatic permission setup.
  This is an unedited 2x capture of the app window: the guest consent dialog, temporary
  capture marker, and host setup panel are all present. It contains no user documents,
  credentials, or account login. The Allow button is around (640, 520) in window points.

The consent test runs Vision OCR on the real pixels and checks the button's location;
the synthetic text cases also check that another app's dialog cannot borrow this
agent's identity from a Settings row.
# Pending control consent on macOS 27

`pending-control-consent-27.png` is the unmodified host-window capture from the isolated build66
macOS 27.0.1 (26A434) fresh-install failure. Accessibility health was already true, while its original
system consent remained visible as Screen Recording was requested. The fixture checks the agent's
own request and its Open System Settings button; the setup sidebar is unrelated text.

`screen-recording-off-27.png` is an unmodified host-read guest framebuffer from build68's
isolated macOS27 retry after a failed fresh install. The recording switch is off. Its test
changes the framebuffer immediately after the first observation and verifies that the
permission row and switch are located in the same image. This models a transition race;
the original failed install did not record its exact switch-click frame, so this fixture
does not establish that race as the sole cause of that failure.
