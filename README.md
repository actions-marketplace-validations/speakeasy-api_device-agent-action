# Speakeasy device agent action

Connect a GitHub Actions job's AI tools to Speakeasy **without storing a Speakeasy secret**. The job proves who it is to Speakeasy with its own GitHub OIDC token. Claude Code and Codex in that job then get the plugins and MCP servers assigned to its Speakeasy agent, and send hook events back to Speakeasy. The tools still sign in to their vendors themselves, for example with an API key.

## Set up Speakeasy (once, as an administrator)

The Speakeasy dashboard sets up GitHub Actions for you. You need permission to manage workload identities, sync device agents and send hook events.

1. Go to **Identities → Agents → New agent identity** and name the agent.
2. Under **MCP Selection**, choose the MCP servers the job may call. Under **MCP sign-in**, choose how Speakeasy signs in to each.
3. Under **Agent sign-in**, choose **GitHub Actions**.
4. Under **Your repository**, enter the owner and repository, choose **Which jobs** get in (see [Subjects](#subjects)), and click **Connect GitHub Actions**.
5. Check **What the job gets**. If it lists no plugin, assign one to Everyone or to a role the agent holds. Then copy the workflow from **Add the workflow** and add the API key secret it names.

To change which jobs get in later, edit the agent.

### What the guided setup does for you

| What | How |
|---|---|
| Trusts GitHub | Reuses or registers `https://token.actions.githubusercontent.com` as an organization-level workload issuer. |
| Admits the jobs | Writes one organization-level rule for the jobs you chose and assigns it to the agent. Warns if a project has its own GitHub issuer. |
| Gives the agent its permissions | `org:device_agent_sync` to fetch plugins, `org:hooks_ingest` to send this project's hook events, and access to the servers from MCP Selection. |
| Shows what the job will get | The plugins installed for Everyone in the project, the servers the job skips (gateways, and servers with no Speakeasy authorization server), and those the agent can't reach. |
| Writes the workflow | Runs this action with your organization ID and project filled in, with every action pinned to a commit SHA. |

### Setting it up by hand

Without the guided setup, for example through the API or the **Custom OIDC issuer** flow under **Advanced**:

1. Register `https://token.actions.githubusercontent.com` as a workload issuer with **Available to** set to **Organization**. Its keys are at `https://token.actions.githubusercontent.com/.well-known/jwks`.
2. Under that issuer, admit one of the rules in [Subjects](#subjects) for the organization and assign it to an agent.
3. Give the agent `org:device_agent_sync`, plus `org:hooks_ingest` for the project the job's `project` input names, and access to each MCP server it should use.
4. Assign the agent its plugins, to Everyone or to a role it holds. The job's MCP servers come from them.

Speakeasy's device-agent token endpoint only reads organization-level issuers and rules, and the Custom OIDC issuer flow defaults to the current project. A project with its own GitHub issuer also checks jobs against that issuer, not the organization's rule, for its own MCP servers.

### Subjects

GitHub sets the token's `sub` claim from the job:

| Job | Subject |
|---|---|
| Push to `main` | `repo:<owner>/<repo>:ref:refs/heads/main` |
| Pull request | `repo:<owner>/<repo>:pull_request` |
| Any job that references an environment, whatever its event | `repo:<owner>/<repo>:environment:<name>` |

**Which jobs** picks the rule:

| Which jobs | Rule | Admits |
|---|---|---|
| Whole repository (default) | `repo:<owner>/<repo>:*` | Every branch, tag, environment and pull request job in the repository. On `pull_request`, forks get no OIDC token. |
| One branch | `repo:<owner>/<repo>:ref:refs/heads/<branch>` | Jobs on that branch with no environment, such as a push or `workflow_dispatch`. Not pull requests. |
| One environment | `repo:<owner>/<repo>:environment:<name>` | Only jobs that reference that environment, so GitHub runs its protection rules (required reviewers, allowed branches) first. |

Use one environment for anything sensitive. Anyone who can push a branch can run a job the whole repository admits. A `pull_request_target` workflow runs in the base repository with its permissions, so with `id-token: write` it gets a token for a fork's pull request too. Set the environment's protection rules before a workflow names it: GitHub creates a missing environment with no rules.

Owner and repository names are case-sensitive. Repositories created, renamed or transferred since July 15, 2026 put IDs in the subject: enter `<owner>@<id>` and `<repo>@<id>`. If a job is refused, the action prints its subject.

## Use it

The action writes each installed tool's configuration, so install the tools and create their configuration directories first.

<details>
<summary><strong>Claude Code</strong></summary>

```yaml
on: workflow_dispatch

jobs:
  agent:
    runs-on: ubuntu-latest
    permissions:
      id-token: write # lets the job request a GitHub OIDC token for Speakeasy
      contents: read
    steps:
      - run: |
          npm install -g @anthropic-ai/claude-code
          mkdir -p "$HOME/.claude"
      - uses: speakeasy-api/device-agent-action@v1
        with:
          organization-id: ${{ vars.SPEAKEASY_ORG_ID }}
          project: ci # hook events go to this project
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          github_token: ${{ github.token }}
          prompt: List the Linear teams I can see.
          claude_args: --allowedTools mcp__speakeasy-linear-1a2b
```

- `claude-code-action` removes GitHub's OIDC request variables from Claude's environment. Speakeasy's token helpers then get their tokens from the speakeasyd this action leaves running, so keep this action before it in the same job.
- Speakeasy MCP servers are named `speakeasy-<server>-<suffix>`. Get the exact names from `claude mcp list` or the sync report, then allow them with `--allowedTools`.

</details>

<details>
<summary><strong>Codex</strong></summary>

```yaml
on: workflow_dispatch

jobs:
  agent:
    runs-on: ubuntu-latest
    permissions:
      id-token: write # lets the job request a GitHub OIDC token for Speakeasy
      contents: read
    steps:
      - run: |
          npm install -g @openai/codex
          mkdir -p "$HOME/.codex"
      - uses: speakeasy-api/device-agent-action@v1
        with:
          organization-id: ${{ vars.SPEAKEASY_ORG_ID }}
          project: ci # hook events go to this project
      - uses: openai/codex-action@v1
        with:
          openai-api-key: ${{ secrets.OPENAI_API_KEY }}
          prompt: List the Linear teams I can see.
```

`codex-action` reads the Speakeasy MCP servers from `~/.codex`, where this action wrote them.

</details>

For fully reproducible builds, pin the action to a commit SHA with a `# v1.x.y` comment, and pin speakeasyd with `version`.

## Inputs

| Input | Required | Description |
|---|---|---|
| `organization-id` | yes | Your Speakeasy organization ID. |
| `project` | no | Speakeasy project slug for this job's hook events. Leave it empty to turn hook events off. |
| `control-plane-url` | no | Defaults to `https://ai.speakeasy.com`. The token audience is built from it, so it must be the host that serves the device-agent API. |
| `version` | no | The speakeasyd to install. Defaults to `latest`, the latest stable release. Set a stable version like `0.1.52` (a leading `v` is fine) for reproducible builds: pinning the action to a SHA doesn't pin speakeasyd. |
| `speakeasyd-binary` | no | Path to a speakeasyd already on the runner, used instead of a release. Only for testing unreleased builds. |

## Outputs

| Output | Description |
|---|---|
| `report` | Path to the JSON report from `speakeasyd sync --once`: the agent, and each tool's status. |
| `skipped` | `true` when the step skipped, for example on a pull request from a fork. |
| `daemon` | `true` when speakeasyd is running for later steps to get tokens from. |
| `version` | The speakeasyd version installed, like `0.1.52`. Empty with `speakeasyd-binary`. |

## How it works

1. **Install.** The action finds the release in Speakeasy's stable release records (`releases.json` for `latest`, `release-history.json` for a pinned `version`) and refuses one Speakeasy has blocked. It downloads the runner's build over HTTPS from Speakeasy's releases bucket, checks its SHA-256 and size against the records, stops on any mismatch, and installs it at `/usr/local/bin/speakeasyd`.
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
| Error: Speakeasy refused this job's GitHub token | Compare the printed subject with the agent's rule (edit the agent to see which jobs it admits; see [Subjects](#subjects)), and check the rule is still assigned to the agent. Set up by hand? Check the issuer and rule are organization-level. Speakeasy gives the same `invalid_grant` for every refusal, so the action can't tell which is wrong. |
| Error naming `org:device_agent_sync` | Give the agent that permission. Its owner must hold it too. |
| Error: did not pick up the GitHub identity | The speakeasyd in use has no GitHub Actions support. Use the latest stable release, or set `version` to one that has it. |
| Error: a speakeasyd version is not a stable release, or is blocked | Set `version` to another stable release, or to `latest`. |
| Error: a speakeasyd SHA-256 or size doesn't match | The download doesn't match Speakeasy's release records. Tell Speakeasy rather than working around it. |
| Warning: a tool is not set up | Install it and create its configuration directory before this step, or read the sync report. |
| Warning: hook events are off | Set the `project` input. |
| An MCP server shows "needs authentication" | Edit the agent and add that server under **MCP Selection**. speakeasyd logs `invalid_grant` for it and backs off. |

## Limits

- **Linux and macOS runners only.** Windows runners are refused.
- **No MCP gateways yet.** Gateways don't accept agents, so the job connects to each MCP server directly.
- **No servers that need a person's sign-in.** A job can't complete an upstream OAuth sign-in.
- **Hook events need hooks 0.3.41 or later** in the observability plugin. Speakeasy rolls new hooks versions out to organizations in stages.

## License

MIT. See [LICENSE](LICENSE).

Maintainers: see [RELEASING.md](RELEASING.md).
