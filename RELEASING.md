# Releasing

Each action release pins one speakeasyd version and its checksums in `action.yml`.

1. Take the version and all four checksums (linux and darwin, amd64 and arm64) from the stable `releases.json` in the `speakeasy-device-agent-releases-prod` bucket.
2. Update `SPEAKEASYD_VERSION` and every `SPEAKEASYD_SHA256_*` in `action.yml` together.
3. Tag the release (`v1.x.y`) and move the major tag (`v1`) to it.

The first release must pin a speakeasyd that has GitHub Actions support (device-agent #240).

## Before the first Marketplace release

- Choose a license and add `LICENSE`.
- Make the repository public.
- Replace `@main` in the README examples with `@v1`, and remove the "Test before the speakeasyd release" section.
