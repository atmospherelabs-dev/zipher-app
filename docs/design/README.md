# Redesign captures

`before/` is the agent-pairing branch (#8); `after/` is this redesign.
`home`, `more` and `status-sheet` are from the iOS simulator (empty test wallet).
`activity`, `swap-recap` and `agent` are rendered by `test/design_capture_test.dart`
with synthetic data:

    ZIPHER_DESIGN_CAPTURE=$PWD/docs/design/after flutter test test/design_capture_test.dart

| Screen | Before | After |
|---|---|---|
| Home | ![](before/home.png) | ![](after/home.png) |
| Wallet status | — | ![](after/status-sheet.png) |
| Activity | ![](before/activity.png) | ![](after/activity.png) |
| Swap recap | ![](before/swap-recap.png) | ![](after/swap-recap.png) |
| More | ![](before/more.png) | ![](after/more.png) |
| Agent | ![](before/agent.png) | ![](after/agent.png) |
| Buttons (About) | — | ![](after/about-buttons.png) |
| Buttons (dialog) | — | ![](after/dialog-buttons.png) |
