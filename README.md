# Speakeasy device agent action

Connects a GitHub Actions job to Speakeasy **with no stored secret**. The job proves who it is with GitHub's own OIDC token. Its AI tools (Claude Code, Codex) then get the plugins and MCP servers assigned to their agent, and send hook events back to Speakeasy.

> **Status: preview.** GitHub Actions support is in device-agent #240, which no speakeasyd release includes yet. Until it ships, the pinned release (0.1.47) stops with "did not pick up the GitHub identity". To test now, build speakeasyd from #240 and pass it as `speakeasyd-binary`.

## Usage

```yaml
permissions:
  id-token: write # lets the job request a GitHub OIDC token
  contents: read

steps:
  # Install the AI tools first: the action writes their configuration.
  - run: npm install -g @anthropic-ai/claude-code
  - uses: speakeasy-api/device-agent-action@v1
    with:
      organization-id: ${{ vars.SPEAKEASY_ORG_ID }}
      project: api-ci
  - run: claude -p "triage this failure" # has Speakeasy MCP servers, no secret
```

### Inputs

| Input | Required | What it is |
|---|---|---|
| `organization-id` | yes | Your Speakeasy organization ID. |
| `project` | no | Speakeasy project slug for this job. Hook events go to it. Empty turns hook events off. |
| `control-plane-url` | no | Defaults to `https://ai.speakeasy.com`. speakeasyd builds the token audience from it, so it must be the host that serves the device-agent API. |
| `speakeasyd-binary` | no | A speakeasyd already on the runner, used instead of the pinned release. For testing unreleased builds only. |

### Outputs

| Output | What it is |
|---|---|
| `report` | Path to the JSON report from `speakeasyd sync --once`. |
| `skipped` | `true` when the step skipped, for example on a pull request from a fork. |
| `daemon` | `true` when a speakeasyd is running for later steps to get tokens from. |

## How it works

1. **Install.** The action downloads the speakeasyd release it pins and stops if the SHA-256 does not match. It installs it at `/usr/local/bin/speakeasyd`.
2. **Configure.** It writes the root-owned managed configuration (`/etc/speakeasy/managed.json` on Linux). That file holds no secret, only where the identity comes from:
   ```json
   {
     "v": 1,
     "environment": "ephemeral",
     "auto_update": "disabled",
     "_control_plane_url": "https://ai.speakeasy.com",
     "workload_identity": {"source": "github_actions", "organization_id": "<org>", "hooks_project_slug": "<project>"}
   }
   ```
3. **Sync once.** `speakeasyd sync --once` does the rest:
   - It asks GitHub for an OIDC token whose audience is `https://ai.speakeasy.com/oauth/workload/device-agent/<org>/token`.
   - It exchanges it there for a 15-minute device-agent token and fetches the agent's plugins.
   - It writes each tool's MCP entries with a helper, `speakeasyd mcp-token`, that gets a fresh token for every connection. No token is written to disk.
4. **Keep a daemon running.** The action starts `speakeasyd` in the background for the rest of the job. `anthropics/claude-code-action` removes GitHub's OIDC request variables from Claude's environment, so the helpers inside Claude can't request GitHub tokens themselves. They get short-lived Speakeasy tokens from the daemon over its owner-only socket instead.

## What an administrator sets up first

| Step | Where in Speakeasy |
|---|---|
| Register `https://token.actions.githubusercontent.com` as a workload issuer, **available to the organization**. A project-level issuer is not found. | Agent → Credentials |
| Admit the job's exact subject, e.g. `repo:<org>/<repo>:ref:refs/heads/main`, and assign it to an agent. A wildcard on GitHub's `sub` admits any branch. | Agent → Credentials |
| Give that agent `org:device_agent_sync`, plus `org:hooks_ingest` for hook events. | Agent → Permissions → Platform access |

## What the job log shows

| Situation | Result |
|---|---|
| Pull request from a fork | Notice, step skipped. GitHub gives forks no OIDC token. |
| No `id-token: write` | Error: add the permission. |
| Speakeasy refuses the token | Error with the job's subject and the three setup steps. Speakeasy gives the same `invalid_grant` for every refusal, so the action cannot say which step is missing. |
| The agent lacks `org:device_agent_sync` | Error naming the permission. |
| A tool is pending or failed | Warning naming the tool. |
| `project` empty | Warning: hook events are off. |

## Known limits

- **Linux and macOS runners only.** Windows is refused (device-agent ADR-0025).
- **Gateways don't accept agents yet** (AIM-82), so a job reaches each MCP server directly.
- **Servers that need a person's sign-in** (upstream OAuth) can't be reached by a job.
- **Hook events need the new hooks relay** (gram #7484) in the plugins.

## Releasing

Each action release pins one speakeasyd version and its checksums in `action.yml`. Bump the version and all four checksums together from the stable `releases.json` in the `speakeasy-device-agent-releases-prod` bucket. Before the first Marketplace release: choose a license and make the repository public.
