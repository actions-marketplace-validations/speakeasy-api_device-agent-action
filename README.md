# Speakeasy device agent action

> **Status: not usable yet.** This repo holds the design. Nothing here runs.

A GitHub Action that connects a workflow job to Speakeasy **with no stored secret**. The job proves who it is with GitHub's own OIDC token, and Speakeasy hands back a short-lived token for that job.

## What it is for

AI tools running in CI (Claude Code, Codex) should get the same Speakeasy setup as a developer's laptop:

- the plugins and MCP servers assigned to them,
- hook events and telemetry sent back to Speakeasy,
- no API key in repository secrets.

## Planned usage

```yaml
permissions:
  id-token: write # lets the job request a GitHub OIDC token
  contents: read

steps:
  - uses: speakeasy-api/device-agent-action@v1
    with:
      organization-id: <your Speakeasy organization ID>
      hooks-project: <project slug for hook events> # optional
  - run: claude -p "triage this failure" # has Speakeasy MCP servers, no secret
```

## How it works

1. **The job asks GitHub for an OIDC token** whose audience is the organization's device-agent token endpoint, `https://ai.speakeasy.com/oauth/workload/device-agent/<organization-id>/token`.
2. **Speakeasy swaps it for a 15-minute token** (RFC 7523 JWT bearer grant). The job acts as a workload, under the live permissions of the agent assigned to it.
3. **The token is used to fetch plugins** (`agent.getPlugins`) and, later, to send hook events. MCP servers get their own short-lived token for each connection, which is never written to disk.

## What an administrator sets up first

| Step | Where |
|---|---|
| Register `https://token.actions.githubusercontent.com` as a workload issuer, available to the **organization** (not one project) | Agent → Credentials |
| Admit the job's subject, e.g. `repo:<org>/<repo>:ref:refs/heads/main`, and assign it to an agent. Prefer exact subjects: a wildcard on GitHub's `sub` admits any branch. | Agent → Credentials |
| Give that agent `org:device_agent_sync`, plus `org:hooks_ingest` for hook events | Agent → Permissions → Platform access |

## Known limits

- **Gateways don't accept agents yet** (AIM-82), so a job reaches each MCP server directly, not through a gateway.
- **Servers that need a person's sign-in** (upstream OAuth) can't be reached by a job.
- **Pull requests from forks get no OIDC token.** The action has to skip cleanly there.
- **Each GitHub token is single use** (its `jti`), and sessions last 15 minutes with no refresh.

## Open questions

- [ ] **Wrap the device agent or stand alone?** Option A installs `speakeasyd` and runs one sync, so policy and hooks come for free. Option B is a small action that only exchanges the token. The device side of A is device-agent #240.
- [ ] **Hooks and telemetry in v1, or MCP only?** Hooks also need the hooks relay that authenticates with this token (gram #7484).
- [ ] **Does `anthropics/claude-code-action` pick up user-scope MCP entries** from `~/.claude.json`?
- [ ] **License,** before the repo goes public.
- [ ] **Marketplace requirements:** public repo, a single `action.yml` at the root, and as far as we know no workflow files, so the action's own tests may need to live elsewhere.
