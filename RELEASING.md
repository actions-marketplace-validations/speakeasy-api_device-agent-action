# Releasing

The action installs the latest stable speakeasyd when it runs, or the release a workflow pins with the `version` input. An action release doesn't touch speakeasyd.

1. Tag the release (`v1.x.y`) and move the major tag (`v1`) to it.

## The first release

1. Wait for a stable speakeasyd release with GitHub Actions support. Until one exists, the action stops with "did not pick up the GitHub identity".
2. Make the repository public.
3. Tag `v1.0.0`, create a GitHub release from it, and point `v1` at it.
4. Optional: publish to the GitHub Marketplace by ticking "Publish this Action to the GitHub Marketplace" on the release. The repository qualifies; keep it that way: one `action.yml` at the root, `branding` set, and no workflow files. The listing name (`name` in `action.yml`) must be unique on the Marketplace.
