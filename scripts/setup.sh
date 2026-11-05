#!/usr/bin/env bash
# Connects this job's AI tools to Speakeasy with the job's GitHub OIDC token:
# installs speakeasyd, writes its managed configuration, and runs one sync.
#
# speakeasyd does the token work itself: it asks the Actions runtime for an
# OIDC token, exchanges it at the organization's device-agent endpoint, and
# writes each tool's MCP entries with a helper that fetches a fresh token per
# connection. This script never sees or prints a Speakeasy token.
set -euo pipefail

ISSUER=https://token.actions.githubusercontent.com

notice() { echo "::notice title=Speakeasy::$*"; }
warn() { echo "::warning title=Speakeasy::$*"; }
fail() {
	echo "::error title=Speakeasy::$*"
	exit 1
}
output() { echo "$1=$2" >>"$GITHUB_OUTPUT"; }

org="${INPUT_ORGANIZATION_ID:-}"
project="${INPUT_PROJECT:-}"
control_plane="${INPUT_CONTROL_PLANE_URL%/}"
channel="${INPUT_CHANNEL:-stable}"
[ -n "$org" ] || fail "Set the organization-id input to your Speakeasy organization ID."
case "$control_plane" in
https://*) ;;
*) fail "control-plane-url must be an https URL, got: $control_plane" ;;
esac

# pull_request_head sets head_repo to the repository a pull request's head is
# in ("a deleted fork" when it has none), or returns 1 when this job's event
# isn't about a pull request. issue_comment names only the pull request, so its
# head comes from the API, and any failure there stops the job: an unknown head
# is never taken for this repository.
pull_request_head() {
	local number response status reason hint
	case "${GITHUB_EVENT_NAME:-}" in
	pull_request | pull_request_target | pull_request_review | pull_request_review_comment | workflow_run)
		head_repo="$(jq -r '(.pull_request.head.repo // .workflow_run.head_repository).full_name // "a deleted fork"' \
			"$GITHUB_EVENT_PATH")" || fail "Could not read this job's $GITHUB_EVENT_NAME event."
		;;
	issue_comment)
		number="$(jq -r 'select(.issue.pull_request) | .issue.number' "$GITHUB_EVENT_PATH")" ||
			fail "Could not read this job's $GITHUB_EVENT_NAME event."
		[ -n "$number" ] || return 1
		response="$(curl --silent --show-error --proto '=https' --tlsv1.2 --retry 3 --max-time 30 -w '\n%{http_code}' \
			-H "Authorization: Bearer ${PR_LOOKUP_TOKEN:-}" -H 'Accept: application/vnd.github+json' \
			"${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/pulls/$number")" ||
			fail "Could not reach the GitHub API to check whether pull request #$number comes from a fork."
		status="${response##*$'\n'}"
		response="${response%$'\n'*}"
		if [ "$status" != 200 ]; then
			reason="$(jq -r '.message // empty' <<<"$response" 2>/dev/null)" || reason=
			hint="Re-run the job."
			case "$status" in
			401 | 403 | 404) hint='Add "permissions: pull-requests: read" to the job.' ;;
			esac
			fail "Could not look up pull request #$number to check whether it comes from a fork (HTTP $status${reason:+: $reason}). $hint"
		fi
		head_repo="$(jq -r '.head.repo.full_name // "a deleted fork"' <<<"$response")" ||
			fail "The GitHub API answered with something other than pull request #$number."
		;;
	*) return 1 ;;
	esac
}

# Pull requests from forks get no Speakeasy access, whatever the event: on
# issue_comment, pull_request_target and workflow_run they get this
# repository's secrets and OIDC token.
if pull_request_head && [ "$head_repo" != "$GITHUB_REPOSITORY" ]; then
	notice "Skipped: this $GITHUB_EVENT_NAME job is for a pull request from $head_repo, not $GITHUB_REPOSITORY. Pull requests from forks get no Speakeasy access."
	output skipped true
	exit 0
fi
unset PR_LOOKUP_TOKEN
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
	fail 'This job has no GitHub OIDC token. Add "permissions: id-token: write" to the job.'
fi
output skipped false

case "${RUNNER_OS:-}" in
Linux)
	os=linux
	managed=/etc/speakeasy/managed.json
	;;
macOS)
	os=darwin
	managed="/Library/Application Support/Speakeasy/managed.json"
	;;
*) fail "Runner OS ${RUNNER_OS:-unknown} is not supported. Use a Linux or macOS runner." ;;
esac
case "${RUNNER_ARCH:-}" in
X64) arch=amd64 ;;
ARM64) arch=arm64 ;;
*) fail "Runner architecture ${RUNNER_ARCH:-unknown} is not supported." ;;
esac

# Install speakeasyd at a fixed path: the MCP entries written below run it as
# a header helper in later steps.
bin=/usr/local/bin/speakeasyd
sudo mkdir -p "$(dirname "$bin")"
if [ -n "${INPUT_SPEAKEASYD_BINARY:-}" ]; then
	[ -x "$INPUT_SPEAKEASYD_BINARY" ] || fail "speakeasyd-binary is not an executable file: $INPUT_SPEAKEASYD_BINARY"
	sudo install -m 0755 "$INPUT_SPEAKEASYD_BINARY" "$bin"
	installed="from $INPUT_SPEAKEASYD_BINARY"
	note="Using speakeasyd $installed, not a release."
	[ "${INPUT_VERSION:-latest}" = latest ] || note="$note The version input is ignored."
	[ "$channel" = stable ] || note="$note The channel input is ignored."
	warn "$note"
else
	download="$RUNNER_TEMP/speakeasyd"
	version="$(bash "$(dirname "$0")/download-speakeasyd.sh" "${INPUT_VERSION:-latest}" "$os" "$arch" "$download" "$channel")"
	sudo install -m 0755 "$download" "$bin"
	rm -f "$download"
	installed="$version ($channel channel)"
	output version "$version"
fi

# The managed layer holds no secret: an organization, a project and where to
# get the identity. It must be root-owned, because speakeasyd refuses a
# control-plane override from a user-writable file.
config="$(jq -n --arg org "$org" --arg cp "$control_plane" --arg project "$project" '{
	v: 1,
	environment: "ephemeral",
	auto_update: "disabled",
	_control_plane_url: $cp,
	workload_identity: ({source: "github_actions", organization_id: $org}
		+ (if $project == "" then {} else {hooks_project_slug: $project} end))
}')"
sudo mkdir -p "$(dirname "$managed")"
printf '%s\n' "$config" | sudo tee "$managed" >/dev/null
sudo chmod 0644 "$managed"

# job_subject sets subject to this job's OIDC subject, the value an
# administrator admits. It requests a throwaway token for a diagnostics
# audience and masks it. It sets a variable instead of printing: a mask command
# printed inside $(...) is captured rather than reaching the runner, and the
# token would land in the log.
subject=unknown
job_subject() {
	local jwt payload sub
	jwt="$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
		"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=speakeasy-diagnostics" | jq -r .value)" || return 0
	{ [ -n "$jwt" ] && [ "$jwt" != null ]; } || return 0
	echo "::add-mask::$jwt"
	payload="$(printf '%s' "$jwt" | cut -d. -f2 | tr '_-' '/+')"
	while [ $((${#payload} % 4)) -ne 0 ]; do payload="$payload="; done
	sub="$(printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r .sub)" || return 0
	[ -z "$sub" ] || subject="$sub"
}

# Speakeasy answers every refused exchange with the same invalid_grant, so the
# log carries what an administrator needs to fix it.
explain_fetch_failure() {
	local errors
	errors="$(cat "$errlog")"
	job_subject
	if grep -q 'control plane answered 4' <<<"$errors"; then
		echo "::error title=Speakeasy::Speakeasy refused this job's GitHub token. Subject: $subject"
		echo "An administrator must, in Speakeasy:"
		echo "  1. Register $ISSUER as a workload issuer available to the organization, not to one project."
		echo "  2. Admit the exact subject $subject under that issuer and assign it to an agent."
		echo "  3. Give that agent org:device_agent_sync (Agent > Permissions > Platform access)."
		exit 1
	fi
	if grep -q 'HTTP 403' <<<"$errors"; then
		fail "Speakeasy accepted this job (subject $subject), but its agent needs org:device_agent_sync. In Speakeasy: Agent > Permissions > Platform access."
	fi
	fail "speakeasyd could not fetch this job's policy: $(tail -n 3 "$errlog")"
}

report="$RUNNER_TEMP/speakeasy-sync.json"
errlog="$RUNNER_TEMP/speakeasy-sync.log"
output report "$report"
set +e
"$bin" sync --once --json >"$report" 2>"$errlog"
code=$?
set -e
case "$code" in
0) ;;
2) explain_fetch_failure ;;
3)
	# The version input is ignored with speakeasyd-binary, so don't suggest it.
	if [ -n "${INPUT_SPEAKEASYD_BINARY:-}" ]; then
		fix="That binary has no GitHub Actions support."
	else
		fix="It has no GitHub Actions support: use the latest $channel release, or set the version input to one that has it."
	fi
	fail "speakeasyd $installed did not pick up the GitHub identity ($(tail -n 1 "$errlog")). $fix"
	;;
*) fail "speakeasyd sync failed (exit $code): $(tail -n 3 "$errlog")" ;;
esac

echo "speakeasyd     $installed"
jq -r '
	"Control plane  \(.control_plane)",
	"Egress         \(.egress)",
	(if .agent then "Agent          \(.agent.name // .agent.principal)" else empty end),
	(.tools[] | "\(.tool | . + " " * (15 - length))\(.status)\(if .reason then " (\(.reason))" else "" end)")
' "$report"
pending="$(jq -r '[.tools[] | select(.status == "pending" or .status == "error") | .tool] | join(", ")' "$report")"
[ -z "$pending" ] || warn "Not set up: $pending. Install those tools before this step, or see the report at $report."
[ -n "$project" ] || warn "Hook events are off: set the project input."

# Some tools run with GitHub's OIDC request variables removed:
# anthropics/claude-code-action deletes them so Claude cannot mint tokens.
# The token helpers then ask a running speakeasyd over its owner-only socket,
# so start one here, where the variables still exist. It hands out short-lived
# Speakeasy tokens, never GitHub ones, and the runner stops it when the job ends.
case "$os" in
darwin) socket="$HOME/Library/Application Support/Speakeasy/agent.sock" ;;
*) socket="$HOME/.speakeasy/agent.sock" ;;
esac
daemon_log="$RUNNER_TEMP/speakeasyd.log"
nohup "$bin" </dev/null >"$daemon_log" 2>&1 &
for _ in $(seq 1 50); do
	[ -S "$socket" ] && break
	sleep 0.2
done
if [ -S "$socket" ]; then
	output daemon true
else
	output daemon false
	warn "speakeasyd did not start, so tools that cannot request GitHub tokens themselves will not connect. See $daemon_log."
fi
notice "Speakeasy is ready for this job."
