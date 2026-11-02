# Releasing

The action installs the latest stable speakeasyd when it runs, or the release a workflow pins with the `version` input. An action release doesn't touch speakeasyd.

1. Tag the release (`v1.x.y`) and move the major tag (`v1`) to it.

## Before the first Marketplace release

- Choose a license and add `LICENSE`.
- Make the repository public.
- Replace `@main` in the README examples with `@v1`.
- Once a stable speakeasyd release has GitHub Actions support (device-agent #296), remove the README's preview note and its "Test before the speakeasyd release" section.
