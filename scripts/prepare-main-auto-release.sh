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
    if [[ "$commit_subject" == *"shortcut modifiers"* && "$commit_subject" == *"input fallback"* ]]; then
      first_note="新增单个按键、组合键和单独修饰键的快捷键录入，并记住用户最后选择的实体输入设备。"
      second_note="虚拟麦克风暂时不可用时，优先恢复用户选择的实体输入设备；快捷键录入不会触发原有系统动作。"
    elif [[ "$commit_subject" == *"shortcut modifiers"* ]]; then
      first_note="新增单个按键、组合键和单独修饰键的快捷键录入。"
      second_note="录入快捷键时会安全拦截本次按键，不触发原有系统或 APP 动作。"
    elif [[ "$commit_subject" == *"input fallback"* ]]; then
      first_note="记住用户最后选择的实体输入设备，并在虚拟麦克风暂时不可用时优先恢复。"
      second_note="用户手动切换输入设备后不会被覆盖，虚拟设备恢复时仍会安全处理默认输入。"
    elif [[ "$commit_subject" == *"HID"* && "$commit_subject" == *"discovery"* ]]; then
      first_note="修复唤醒后 HID 发现管理器卡住、遥控器按键迟迟无法恢复的问题。"
      second_note="现在会有限次数重建发现管理器，并在收到有效按键后停止恢复任务，避免持续轮询。"
    elif [[ "$commit_subject" == *"HID"* && "$commit_subject" == *"mapping"* ]]; then
      first_note="修复系统唤醒后蓝牙已连接但 HID 服务延迟出现时，遥控器按键映射可能失效的问题。"
      second_note="现在会在有限时间内自动退避重试，并在成功、断开或关闭软件时安全停止。"
    elif [[ "$commit_subject" == *"voice key modes"* || "$commit_subject" == *"rapid presses"* ]]; then
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
    if [[ "$commit_subject" == *"shortcut modifiers"* && "$commit_subject" == *"input fallback"* ]]; then
      first_note="Added recording for single keys, key combinations, and standalone modifiers, plus remembered physical input fallback."
      second_note="The app prioritizes the user's last physical input when the virtual microphone is temporarily unavailable and safely suppresses the recorded keystroke."
    elif [[ "$commit_subject" == *"shortcut modifiers"* ]]; then
      first_note="Added recording for single keys, key combinations, and standalone modifiers."
      second_note="Shortcut capture safely suppresses the recorded keystroke so the existing system or app action is not triggered."
    elif [[ "$commit_subject" == *"input fallback"* ]]; then
      first_note="Remembered the user's last physical input and prioritize it when the virtual microphone is temporarily unavailable."
      second_note="Manual input changes are preserved while virtual-device fallback and restoration remain safely managed."
    elif [[ "$commit_subject" == *"HID"* && "$commit_subject" == *"discovery"* ]]; then
      first_note="Fixed the HID discovery manager getting stuck after wake and leaving remote buttons unavailable."
      second_note="The app now performs bounded manager rebuilds and stops recovery after a valid button report instead of polling forever."
    elif [[ "$commit_subject" == *"HID"* && "$commit_subject" == *"mapping"* ]]; then
      first_note="Fixed remote button mappings being unavailable when Bluetooth recovered before HID services appeared after system wake."
      second_note="The app now retries with bounded backoff and stops safely after success, disconnect, or shutdown."
    elif [[ "$commit_subject" == *"voice key modes"* || "$commit_subject" == *"rapid presses"* ]]; then
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
