#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
DRIVER="$OUTPUT_DIR/MiRemoteV2ch.driver"
APP="$OUTPUT_DIR/Remote Mic.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
INSTALL_PACKAGE="$OUTPUT_DIR/$RELEASE_INSTALL_PACKAGE_NAME"
LEGACY_INSTALL_PACKAGE="$OUTPUT_DIR/安装豆包兼容麦克风.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/$RELEASE_UNINSTALL_PACKAGE_NAME"
LEGACY_UNINSTALL_PACKAGE="$OUTPUT_DIR/卸载豆包兼容麦克风.pkg"
INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:--}"
INSTALLER_SIGNING_KEYCHAIN="${INSTALLER_SIGNING_KEYCHAIN:-${NOTARY_KEYCHAIN:-}}"
PRODUCTSIGN_TIMEOUT_SECONDS="${PRODUCTSIGN_TIMEOUT_SECONDS:-900}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
WORK_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.doubao-driver-package.XXXXXX")"
PAYLOAD_ROOT="$WORK_DIR/payload"
INSTALL_SCRIPTS="$WORK_DIR/install-scripts"
UNINSTALL_SCRIPTS="$WORK_DIR/uninstall-scripts"
UNSIGNED_INSTALL_PACKAGE="$WORK_DIR/Install Remote Mic-unsigned.pkg"
UNSIGNED_UNINSTALL_PACKAGE="$WORK_DIR/Uninstall Remote Mic-unsigned.pkg"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.doubao-driver-package."*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

test -x /usr/bin/pkgbuild
case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$INSTALLER_SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Installer signing is required"
  exit 1
fi
if ! [[ "$PRODUCTSIGN_TIMEOUT_SECONDS" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "PRODUCTSIGN_TIMEOUT_SECONDS must be a positive integer"
  exit 1
fi
PRODUCTSIGN_KEYCHAIN_ARGS=()
if [[ -n "$INSTALLER_SIGNING_KEYCHAIN" ]]; then
  test -f "$INSTALLER_SIGNING_KEYCHAIN"
  PRODUCTSIGN_KEYCHAIN_ARGS=(--keychain "$INSTALLER_SIGNING_KEYCHAIN")
fi
"$ROOT/scripts/verify-doubao-driver.sh" "$DRIVER"
"$ROOT/scripts/verify-app.sh" "$APP"

/bin/rm -f -- \
  "$INSTALL_PACKAGE" \
  "$LEGACY_INSTALL_PACKAGE" \
  "$UNINSTALL_PACKAGE" \
  "$LEGACY_UNINSTALL_PACKAGE"
/bin/mkdir -p \
  "$PAYLOAD_ROOT/Applications" \
  "$PAYLOAD_ROOT/Library/Application Support/RemoteMic/Installer"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$APP" "$PAYLOAD_ROOT/Applications/Remote Mic.app"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$DRIVER" \
  "$PAYLOAD_ROOT/Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/install" "$INSTALL_SCRIPTS"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$RELEASE_CONFIG_PLIST" "$INSTALL_SCRIPTS/release-variant.plist"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/uninstall" "$UNINSTALL_SCRIPTS"

/usr/bin/pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$INSTALL_SCRIPTS" \
  --identifier "com.hd838a.RemoteMic.installer" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$UNSIGNED_INSTALL_PACKAGE"

/usr/bin/pkgbuild \
  --nopayload \
  --scripts "$UNINSTALL_SCRIPTS" \
  --identifier "com.hd838a.MiRemoteV2ch.uninstaller" \
  --version "$VERSION" \
  "$UNSIGNED_UNINSTALL_PACKAGE"

sign_product() {
  local input_package="$1"
  local output_package="$2"
  local productsign_pid
  local timeout_pid
  local exit_code

  /usr/bin/productsign --sign "$INSTALLER_SIGNING_IDENTITY" \
    "${PRODUCTSIGN_KEYCHAIN_ARGS[@]}" \
    "$input_package" "$output_package" &
  productsign_pid=$!
  (
    /bin/sleep "$PRODUCTSIGN_TIMEOUT_SECONDS"
    if /bin/kill -0 "$productsign_pid" >/dev/null 2>&1; then
      print -u2 "productsign timed out after ${PRODUCTSIGN_TIMEOUT_SECONDS}s: $input_package"
      /bin/kill "$productsign_pid" >/dev/null 2>&1 || true
    fi
  ) &
  timeout_pid=$!

  if wait "$productsign_pid"; then
    /bin/kill "$timeout_pid" >/dev/null 2>&1 || true
    wait "$timeout_pid" >/dev/null 2>&1 || true
  else
    exit_code=$?
    /bin/kill "$timeout_pid" >/dev/null 2>&1 || true
    wait "$timeout_pid" >/dev/null 2>&1 || true
    return "$exit_code"
  fi
}

if [[ "$INSTALLER_SIGNING_IDENTITY" != "-" ]]; then
  test -x /usr/bin/productsign
  sign_product "$UNSIGNED_INSTALL_PACKAGE" "$INSTALL_PACKAGE"
  sign_product "$UNSIGNED_UNINSTALL_PACKAGE" "$UNINSTALL_PACKAGE"
else
  /bin/mv "$UNSIGNED_INSTALL_PACKAGE" "$INSTALL_PACKAGE"
  /bin/mv "$UNSIGNED_UNINSTALL_PACKAGE" "$UNINSTALL_PACKAGE"
fi

"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

print "Built: $INSTALL_PACKAGE"
print "Built: $UNINSTALL_PACKAGE"
print "RELEASE VARIANT: $RELEASE_VARIANT"
print "INSTALLER SIGNING IDENTITY: $INSTALLER_SIGNING_IDENTITY"
