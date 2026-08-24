#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
REPOSITORY="${GITHUB_REPOSITORY:-MaydayV/remote-mic-app}"

if [[ "$REPOSITORY" != "MaydayV/remote-mic-app" ]]; then
  print -u2 "automatic release is restricted to MaydayV/remote-mic-app"
  exit 1
fi
if [[ "${GITHUB_REF_NAME:-}" != "main" ]]; then
  print -u2 "automatic release requires the main branch"
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "automatic release requires a clean checkout before generated metadata"
  exit 1
fi

for command_name in gh git plutil; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

BASE_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BASE_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ ! "$BASE_VERSION" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' || ! "$BASE_BUILD" =~ '^[0-9]+$' ]]; then
  print -u2 "Info.plist must contain a semantic version and numeric build"
  exit 1
fi
base_major="${match[1]}"
base_minor="${match[2]}"
base_patch="${match[3]}"

latest_tag="$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name 2>/dev/null || true)"
version="$BASE_VERSION"
if [[ "$latest_tag" =~ '^v([0-9]+)\.([0-9]+)\.([0-9]+)$' ]]; then
  latest_major="${match[1]}"
  latest_minor="${match[2]}"
  latest_patch="${match[3]}"
  if (( latest_major > base_major ||
        (latest_major == base_major && latest_minor > base_minor) ||
        (latest_major == base_major && latest_minor == base_minor && latest_patch >= base_patch) )); then
    version="$latest_major.$latest_minor.$((latest_patch + 1))"
  fi
fi

run_number="${GITHUB_RUN_NUMBER:-0}"
if [[ ! "$run_number" =~ '^[0-9]+$' ]]; then
  print -u2 "GITHUB_RUN_NUMBER must be numeric"
  exit 1
fi
build="$((BASE_BUILD + 100000 + run_number))"
release_tag="v$version"
commit_sha="$(git rev-parse HEAD)"
commit_short_sha="$(git rev-parse --short=7 HEAD)"
commit_subject="$(git log -1 --format=%s)"

/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$PLIST"
/usr/bin/plutil -replace CFBundleVersion -string "$build" "$PLIST"

for locale in zh-Hans en; do
  history="$ROOT/Resources/$locale.lproj/ReleaseHistory.md"
  temporary="$(/usr/bin/mktemp "/private/tmp/remotemic-auto-history.XXXXXX")"
  if [[ "$locale" == "zh-Hans" ]]; then
    first_note="自动发布：$commit_subject"
    second_note="本次构建提交：$commit_short_sha"
  else
    first_note="Automatic release: $commit_subject"
    second_note="Build commit: $commit_short_sha"
  fi
  {
    print "## $version"
    print
    print "- $first_note"
    print "- $second_note"
    print
    /bin/cat "$history"
  } > "$temporary"
  /bin/mv "$temporary" "$history"
done

if [[ -n "${GITHUB_ENV:-}" ]]; then
  print "RELEASE_TAG=$release_tag" >> "$GITHUB_ENV"
  print "RELEASE_VERSION=$version" >> "$GITHUB_ENV"
  print "RELEASE_BUILD=$build" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  print "tag=$release_tag" >> "$GITHUB_OUTPUT"
  print "version=$version" >> "$GITHUB_OUTPUT"
  print "build=$build" >> "$GITHUB_OUTPUT"
  print "commit=$commit_sha" >> "$GITHUB_OUTPUT"
fi

print "AUTO RELEASE PREPARED: $release_tag ($build)"
print "COMMIT: $commit_sha"
