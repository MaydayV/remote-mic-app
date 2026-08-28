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
# A failed run may have created the tag before signing or notarization failed.
# Keep that immutable provenance and advance to the next patch version instead
# of trying to retag a different main commit over it.
collision_count=0
while git ls-remote --exit-code --refs origin "refs/tags/$release_tag" >/dev/null 2>&1; do
  if [[ ! "$version" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]]; then
    print -u2 "generated release version is not semantic: $version"
    exit 1
  fi
  version="${match[1]}.${match[2]}.$((match[3] + 1))"
  release_tag="v$version"
  collision_count=$((collision_count + 1))
  if (( collision_count >= 100 )); then
    print -u2 "could not find an unused release tag after 100 attempts"
    exit 1
  fi
done
commit_sha="$(git rev-parse HEAD)"

/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$PLIST"
/usr/bin/plutil -replace CFBundleVersion -string "$build" "$PLIST"

for locale in zh-Hans en; do
  history_path="$ROOT/Resources/$locale.lproj/ReleaseHistory.md"
  temporary="$(/usr/bin/mktemp "/private/tmp/remotemic-auto-history.XXXXXX")"
  commit_subject="$(git log -1 --format=%s)"
  if [[ "$locale" == "zh-Hans" ]]; then
    if [[ "$commit_subject" == *"voice key modes"* || "$commit_subject" == *"rapid presses"* ]]; then
      first_note="新增微信输入法自动切换，以及 Fn、左 Command、右 Command 三种语音键模式。"
      second_note="不可重复的自定义动作可按按钮单独允许快速连续点按；默认行为和原有 Fn 路径保持不变。"
    elif [[ "$commit_subject" == *"remote scroll actions"* ]]; then
      first_note="新增遥控器向上滚动和向下滚动动作，可直接控制聊天窗口内容。"
      second_note="滚动事件优先定位前台窗口，无法取得窗口信息时安全回退到当前指针位置。"
    else
      first_note="修复已知问题，提升遥控器兼容性与运行稳定性。"
      second_note="优化更新流程与界面体验。"
    fi
  else
    if [[ "$commit_subject" == *"voice key modes"* || "$commit_subject" == *"rapid presses"* ]]; then
      first_note="Added WeChat input-method switching and Fn, Left Command, and Right Command voice-key modes."
      second_note="Non-repeatable custom actions can opt into rapid repeated presses; existing defaults and the Fn path remain unchanged."
    elif [[ "$commit_subject" == *"remote scroll actions"* ]]; then
      first_note="Added remote-control actions for scrolling up and down in conversation windows."
      second_note="Scroll events target the frontmost window and safely fall back to the current pointer location when needed."
    else
      first_note="Fixed known issues and improved remote compatibility and runtime stability."
      second_note="Refined the update flow and overall interface experience."
    fi
  fi
  {
    print "## $version"
    print
    print -- "- $first_note"
    print -- "- $second_note"
    print
    /bin/cat "$history_path"
  } > "$temporary"
  /bin/mv "$temporary" "$history_path"
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
