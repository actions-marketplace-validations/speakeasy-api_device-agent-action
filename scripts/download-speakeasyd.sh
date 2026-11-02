#!/usr/bin/env bash
# Downloads a stable speakeasyd release for one platform and verifies it.
#
#   download-speakeasyd.sh VERSION GOOS GOARCH OUT
#
# VERSION is "latest" (or empty) for the stable channel's latest release, or
# X.Y.Z with an optional leading "v". The binary lands at OUT only once its
# SHA-256 (and size) match the stable release records. The version is the only
# thing printed on stdout; messages, workflow commands included, go to stderr.
#
# Sources, all in the releases bucket:
#   releases.json         the stable manifest: latest release, blocked_versions
#   release-history.json  every release promoted to stable, for a pinned VERSION
# Both have the same artifact records ({goos, goarch, url, sha256, size}) that
# speakeasyd's own updater reads (device-agent core/updater). A manifest
# pinned_target needs no handling here: it already repoints latest.
set -euo pipefail

RELEASES=https://storage.googleapis.com/speakeasy-device-agent-releases-prod

fail() {
	echo "::error title=Speakeasy::$*" >&2
	exit 1
}

[ $# -eq 4 ] || fail "usage: download-speakeasyd.sh VERSION GOOS GOARCH OUT"
requested="$1"
goos="$2"
goarch="$3"
out="$4"

case "$requested" in
'' | latest)
	requested=latest
	label="latest stable"
	;;
*)
	[[ "$requested" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		fail "The version input must be latest or a speakeasyd version like 0.1.52, got: $requested"
	requested="${requested#v}"
	label=pinned
	;;
esac

if command -v sha256sum >/dev/null; then
	sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
	sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# HTTPS only and no redirects: a moved object fails here rather than being
# fetched from somewhere else.
fetch() {
	curl --fail --silent --show-error --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"
}

# A stable records file with a schema this script was written for, or stop.
fetch_records() {
	fetch "$RELEASES/$1" "$tmp/$1" || fail "Could not fetch $RELEASES/$1."
	jq -e '.schema_version == 1' "$tmp/$1" >/dev/null 2>&1 ||
		fail "$RELEASES/$1 is not a speakeasyd records file this action understands. Update the action."
}

fetch_records releases.json
latest="$(jq -r '.latest.speakeasyd.version // empty' "$tmp/releases.json")"
[ -n "$latest" ] || fail "The stable releases.json lists no speakeasyd release."

if [ "$requested" = latest ] || [ "$requested" = "$latest" ]; then
	version="$latest"
	records="$tmp/releases.json"
	release='.latest.speakeasyd'
else
	version="$requested"
	fetch_records release-history.json
	records="$tmp/release-history.json"
	# shellcheck disable=SC2016 # $v is a jq variable
	release='.versions[] | select(.version == $v) | .binaries.speakeasyd'
	if ! jq -e --arg v "$version" "$release" "$records" >/dev/null; then
		recent="$(jq -r '[.versions[].version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] | .[-3:] | join(", ")' "$records")"
		fail "speakeasyd $version is not a stable release. Recent stable releases: $recent."
	fi
fi

# The kill switch: never install a yanked build, latest or pinned.
if jq -e --arg v "$version" 'any(.blocked_versions[]?; . == $v)' "$tmp/releases.json" >/dev/null; then
	if [ "$requested" = latest ]; then
		fail "The latest stable speakeasyd, $version, is blocked. Set the version input to an earlier stable release."
	fi
	fail "speakeasyd $version is blocked. Set the version input to another stable release, or to latest."
fi

artifact="$(jq -c --arg v "$version" --arg os "$goos" --arg arch "$goarch" \
	"[$release | .artifacts[] | select(.goos == \$os and .goarch == \$arch)] | first // empty" "$records")"
[ -n "$artifact" ] || fail "speakeasyd $version has no build for $goos/$goarch."
url="$(jq -r '.url // empty' <<<"$artifact")"
want="$(jq -r '.sha256 // empty' <<<"$artifact" | tr 'A-F' 'a-f')"
size="$(jq -r '.size // 0' <<<"$artifact")"

# Only plain paths inside the bucket: no dot segments, queries or escapes.
path="${url#"$RELEASES"/}"
if [ "$path" = "$url" ] || ! [[ "$path" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
	[[ "/$path/" == */../* || "/$path/" == */./* ]]; then
	fail "The speakeasyd $version artifact URL is outside the releases bucket: $url. Stopped."
fi
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || fail "The stable records have no valid SHA-256 for speakeasyd $version $goos/$goarch. Stopped."
[[ "$size" =~ ^[0-9]+$ ]] || fail "The stable records have an invalid size for speakeasyd $version $goos/$goarch. Stopped."

echo "Downloading speakeasyd $version ($label, $goos/$goarch)" >&2
fetch "$url" "$tmp/speakeasyd" || fail "Could not download $url."
got="$(sha256 "$tmp/speakeasyd")"
[ "$got" = "$want" ] ||
	fail "speakeasyd $version for $goos/$goarch has SHA-256 $got, but the stable release records say $want. Stopped."
got_size="$(wc -c <"$tmp/speakeasyd" | tr -d ' ')"
[ "$size" -eq 0 ] || [ "$got_size" -eq "$size" ] ||
	fail "speakeasyd $version for $goos/$goarch is $got_size bytes, but the stable release records say $size. Stopped."
echo "Verified SHA-256 $got" >&2

chmod 0755 "$tmp/speakeasyd"
mv "$tmp/speakeasyd" "$out"
echo "$version"
