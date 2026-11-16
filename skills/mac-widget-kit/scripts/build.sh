#!/bin/bash
# 用法:build.sh <dir>
# 用 swiftc(免 Xcode)編譯成 build/<Name>.app,ad-hoc 簽章。印出警告數;編譯失敗結束碼非 0。
source "$(dirname "$0")/_common.sh"
load_widget "$@"
mkdir -p "$APP_PATH/Contents/MacOS"
log="$WIDGET_DIR/build/build.log"
set +e
swiftc -swift-version 6 -O -o "$APP_BIN" "$WIDGET_DIR"/*.swift >"$log" 2>&1
rc=$?
set -e
warnings=$(grep -c ': warning:' "$log" || true)
errors=$(grep -c ': error:' "$log" || true)
if [ $rc -ne 0 ]; then
  cat "$log" >&2
  echo "編譯失敗:錯誤 $errors,警告 $warnings" >&2
  exit $rc
fi
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>WidgetProjectDir</key><string>$WIDGET_DIR</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP_PATH" >/dev/null 2>&1 || die "codesign 失敗"
[ "$warnings" -gt 0 ] && grep ': warning:' "$log" >&2
echo "編譯成功:$APP_PATH"
echo "警告:$warnings"
