# Speakeasy device agent action

Connect a GitHub Actions job's AI tools to Speakeasy **without storing a secret**. The job proves who it is with its own GitHub OIDC token. Claude Code and Codex in that job then get the plugins and MCP servers assigned to its Speakeasy agent, and send hook events back to Speakeasy.

> [!IMPORTANT]
> **Preview.** The action needs a speakeasyd with GitHub Actions support, which no speakeasyd release includes yet. The release it pins (0.1.47) stops with "did not pick up the GitHub identity". Until a release ships, build speakeasyd from source and pass it as `speakeasyd-binary` (see [Test before the speakeasyd release](#test-before-the-speakeasyd-release)). There is no `v1` tag yet either, so the examples use `@main`.

## Set up Speakeasy (once, as an administrator)

| Step | Why |
|---|---|
| Register `https://token.actions.githubusercontent.com` as a workload issuer, **available to the organization**. | Speakeasy doesn't look up project-level issuers for this. |
| Under that issuer, admit the job's exact subject and assign it to an agent. | The admission decides which jobs get in. See [Subjects](#subjects). |
| Give the agent `org:device_agent_sync`. Add `org:hooks_ingest` if you want hook events. | They let the job fetch its plugins and send hook events. |
| Assign the agent the plugins it should get. | The job's MCP servers come from those plugins, and hook events need the observability plugin. |
| Give the agent access to each MCP server it should use. | Servers the agent can't access show as "needs authentication". |

### Subjects

GitHub sets the token's `sub` claim from the event that ran the job:

| Job | Subject |
|---|---|
| Push to `main` | `repo:<owner>/<repo>:ref:refs/heads/main` |
| Pull request | `repo:<owner>/<repo>:pull_request` |
| Deployment environment | `repo:<owner>/<repo>:environment:<name>` |

Admit exact subjects. A wildcard on `sub` lets in every branch and every pull request of the repository. If a job is refused, the action prints its subject so you can copy it.

## Use it

The action writes each installed tool's configuration, so install the tools first.

```yaml
permissions:
  id-token: write # lets the job request a GitHub OIDC token
  contents: read

steps:
  - run: npm install -g @anthropic-ai/claude-code
  - uses: speakeasy-api/device-agent-action@main
    with:
      organization-id: ${{ vars.SPEAKEASY_ORG_ID }}
      project: ci # hook events go to this project
  - run: claude -p "Summarize the open incidents" # has the agent's Speakeasy MCP servers
```

### With `anthropics/claude-code-action`

This works with no stored secret on either side: the Anthropic API takes the job's OIDC token through workload identity federation, and Speakeasy takes it through this action.

```yaml
steps:
  - run: npm install -g @anthropic-ai/claude-code
  - uses: speakeasy-api/device-agent-action@main
    with:
      organization-id: ${{ vars.SPEAKEASY_ORG_ID }}
      project: ci
  - uses: anthropics/claude-code-action@v1
    with:
      anthropic_federation_rule_id: ${{ vars.ANTHROPIC_FEDERATION_RULE_ID }}
      anthropic_organization_id: ${{ vars.ANTHROPIC_ORG_ID }}
      anthropic_service_account_id: ${{ vars.ANTHROPIC_SERVICE_ACCOUNT_ID }}
      anthropic_workspace_id: ${{ vars.ANTHROPIC_WORKSPACE_ID }}
      github_token: ${{ github.token }}
      display_report: false # keeps tool output out of the step summary
      prompt: List the Linear teams I can see.
      claude_args: --allowedTools mcp__speakeasy-linear-1a2b
```

- `claude-code-action` removes GitHub's OIDC request variables from Claude's environment. Speakeasy's token helpers then get their tokens from the speakeasyd this action leaves running, so keep this action before it in the same job.
- Speakeasy MCP servers are named `speakeasy-<server>-<suffix>`. Get the exact names from `claude mcp list` or the sync report, then allow them with `--allowedTools`.

## Inputs

| Input | Required | Description |
|---|---|---|
| `organization-id` | yes | Your Speakeasy organization ID. |
| `project` | no | Speakeasy project slug for this job's hook events. Leave it empty to turn hook events off. |
| `control-plane-url` | no | Defaults to `https://ai.speakeasy.com`. The token audience is built from it, so it must be the host that serves the device-agent API. |
| `speakeasyd-binary` | no | Path to a speakeasyd already on the runner, used instead of the pinned release. Only for testing unreleased builds. |

## Outputs

| Output | Description |
|---|---|
| `report` | Path to the JSON report from `speakeasyd sync --once`: the agent, and each tool's status. |
| `skipped` | `true` when the step skipped, for example on a pull request from a fork. |
| `daemon` | `true` when speakeasyd is running for later steps to get tokens from. |

## How it works

1. **Install.** The action downloads the speakeasyd release it pins, checks its SHA-256 and installs it at `/usr/local/bin/speakeasyd`.
2. **Configure.** It writes a root-owned managed configuration (`/etc/speakeasy/managed.json` on Linux). The file holds no secret, only where the identity comes from:
   ```json
   {
     "v": 1,
     "environment": "ephemeral",
     "auto_update": "disabled",
     "_control_plane_url": "https://ai.speakeasy.com",
     "workload_identity": {"source": "github_actions", "organization_id": "<org>", "hooks_project_slug": "<project>"}
   }
   ```
3. **Sync once.** `speakeasyd sync --once` requests a GitHub OIDC token for the audience `https://ai.speakeasy.com/oauth/workload/device-agent/<org>/token`. It exchanges it there for a 15-minute Speakeasy token and fetches the agent's plugins. Then it writes each tool's MCP entries with a helper, `speakeasyd mcp-token`, that gets a fresh token for each connection.
4. **Keep speakeasyd running.** The action starts speakeasyd in the background for the rest of the job. Token helpers in later steps ask it over its owner-only socket when they can't request a GitHub token themselves.

Nothing writes a token to disk or to the job log. speakeasyd only hands out short-lived Speakeasy tokens, never GitHub ones, and the runner stops it when the job ends.

## Troubleshooting

| What you see | What to do |
|---|---|
| Notice: skipped on a pull request from a fork | Nothing. GitHub gives fork pull requests no OIDC token. |
| Error: the job has no GitHub OIDC token | Add `id-token: write` to the job's `permissions`. |
| Error: Speakeasy refused this job's GitHub token | Check the first two setup steps for the subject printed in the error. Speakeasy gives the same `invalid_grant` for every refusal, so the action can't tell which step is missing. |
| Error naming `org:device_agent_sync` | Give the agent that permission. |
| Error: did not pick up the GitHub identity | The speakeasyd in use has no GitHub Actions support. See the preview note at the top. |
| Warning: a tool is not set up | Install it before this step, or read the sync report. |
| Warning: hook events are off | Set the `project` input. |
| An MCP server shows "needs authentication" | Give the agent access to that server. speakeasyd logs `invalid_grant` for it and backs off. |

## Limits

- **Linux and macOS runners only.** Windows runners are refused.
- **No MCP gateways yet.** Gateways don't accept agents, so the job connects to each MCP server directly.
- **No servers that need a person's sign-in.** A job can't complete an upstream OAuth sign-in.
- **Hook events need hooks 0.3.41 or later** in the observability plugin. Speakeasy rolls new hooks versions out to organizations in stages.

## Test before the speakeasyd release

Build speakeasyd from the device-agent branch with GitHub Actions support and pass it in:

```yaml
- uses: actions/checkout@v7
  with:
    repository: speakeasy-api/device-agent
    ref: brad/dno-1341-da-mint-and-rotate-the-mcpconnect-credential-from-the
    path: device-agent
- uses: actions/setup-go@v7
  with:
    go-version-file: device-agent/go.mod
- run: CGO_ENABLED=0 go build -o "$RUNNER_TEMP/speakeasyd" ./cmd/speakeasyd
  working-directory: device-agent
- uses: speakeasy-api/device-agent-action@main
  with:
    organization-id: ${{ vars.SPEAKEASY_ORG_ID }}
    project: ci
    speakeasyd-binary: ${{ runner.temp }}/speakeasyd
```

Maintainers: see [RELEASING.md](RELEASING.md).
