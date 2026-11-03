# Releasing

The action and speakeasyd are numbered independently. In this file, `v0.1.x` tags are the action's and `0.1.52` is a speakeasyd version. The action installs the latest stable speakeasyd when it runs, or the release a workflow pins with the `version` input, so an action release doesn't touch speakeasyd.

## Versions

- Action releases are `v0.1.x` for now. The moving tag `v0.1` points at the latest `v0.1.x`, so `@v0.1` gets every patch.
- A breaking change goes to `v0.2.0` with a new `v0.2` tag. Update the README's `@v0.1` and `v0.1.x` references with it.
- There is no `v0` tag: in 0.x semver a minor version may break, so `v0` would hand breaking changes to everyone on it.
- `v1` comes later, once the interface is stable. The workflow moves only the minor tag (`v1.0` for `v1.0.x`), so decide then whether it should move a `v1` major tag too.

## Release a version

1. Tag the commit on `main` and push the tag, for example `git tag v0.1.1 && git push origin v0.1.1`.
2. The [release workflow](.github/workflows/release.yml) creates the GitHub release with generated notes and moves the minor tag (`v0.1`) to it. It refuses any tag that isn't exactly `vMAJOR.MINOR.PATCH`, and leaves the minor tag alone if a later patch in the series already exists. If it fails, re-run it: it skips a release that already exists.
3. To list the version on the GitHub Marketplace, edit its release on GitHub and tick "Publish this Action to the GitHub Marketplace". Only the web UI has that box, so the workflow's releases aren't listed until you do.

## The first release

1. Wait for a stable speakeasyd release with GitHub Actions support (device-agent #296). Until one exists, the action stops with "did not pick up the GitHub identity".
2. Update the speakeasyd `0.1.52` examples (README, `action.yml`, and the version error in `scripts/download-speakeasyd.sh`) to that version.
3. Tag `v0.1.0` and push it. The workflow creates the release and the `v0.1` tag.
4. Optional: list it on the GitHub Marketplace, as above. The [requirements](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace): a public repository, a single `action.yml` at the root, and a `name` that's unique on the Marketplace. `branding` sets the listing's icon. Workflow files are allowed: GitHub [dropped the rule against them](https://github.com/github/docs/commit/0130d0a7137856e71667ad9eecc7e3a814cc1e05).
