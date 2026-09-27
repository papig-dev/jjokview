#!/bin/zsh
# 배포용 DMG 만들기.
#   scripts/release.sh            Developer ID 서명 → 앱 공증·스테이플 → DMG 서명 → DMG 공증·스테이플 (배포용)
#   scripts/release.sh adhoc      임시 서명 DMG (이 맥에서 확인용, 다른 맥에서는 Gatekeeper가 막는다)
#
# 필요한 것(배포용):
#   - 키체인의 "Developer ID Application" 인증서 (Xcode → Settings → Accounts → Manage Certificates, 계정 소유자만 만들 수 있다)
#   - 공증용 App Store Connect API 키(환경 변수)
#     ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8  ASC_KEY_ID=XXXX  ASC_ISSUER=<issuer uuid>
# 앱과 DMG 둘 다 스테이플한다. 앱만 따로 옮기거나 오프라인에서 처음 열어도 공증 확인이 된다.
set -euo pipefail
cd "${0:A:h}/.."

MODE=${1:-developer-id}
TEAM=GBN9T65259
VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?.*/\1/p' project.yml | head -1)
OUT=build/release
ARCHIVE=$OUT/Jjokview.xcarchive
EXPORT=$OUT/export
DMG=$OUT/Jjokview-$VERSION.dmg

if [[ $MODE != adhoc ]]; then
    # 오래 걸리는 빌드 전에 먼저 확인한다.
    for v in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER; do
        [[ -n "${(P)v:-}" ]] || { echo "환경 변수 $v 가 필요합니다(공증용 API 키)" >&2; exit 1; }
    done
    [[ -f "${ASC_KEY_PATH:A}" ]] || { echo "API 키 파일이 없습니다: $ASC_KEY_PATH" >&2; exit 1; }
    security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" \
        || { echo "키체인에 Developer ID Application 인증서($TEAM)가 없습니다" >&2; exit 1; }
fi

rm -rf "$ARCHIVE" "$EXPORT" "$OUT/dmg" "$DMG"
mkdir -p "$OUT"
xcodegen generate --quiet

notarize() {   # $1 = 올릴 파일(zip 또는 dmg)
    xcrun notarytool submit "$1" --key "${ASC_KEY_PATH:A}" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait \
        | tee "$OUT/notary.log"
    grep -q "status: Accepted" "$OUT/notary.log" || { echo "공증 실패: $1 (xcrun notarytool log <id> 로 확인)" >&2; exit 1; }
}

echo "==> 아카이브 ($VERSION, $MODE)"
if [[ $MODE == adhoc ]]; then
    xcodebuild -project Jjokview.xcodeproj -scheme Jjokview -configuration Release -archivePath "$ARCHIVE" \
        CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= archive -quiet
    mkdir -p "$EXPORT"
    ditto "$ARCHIVE/Products/Applications/Jjokview.app" "$EXPORT/Jjokview.app"
else
    xcodebuild -project Jjokview.xcodeproj -scheme Jjokview -configuration Release -archivePath "$ARCHIVE" archive -quiet
    cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
    echo "==> Developer ID로 내보내기"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet
fi

APP=$EXPORT/Jjokview.app
codesign --verify --deep --strict "$APP"
SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
if [[ $MODE != adhoc ]]; then
    [[ $SIGN_INFO == *"Authority=Developer ID Application"* ]] || { echo "Developer ID 서명이 아님" >&2; exit 1; }
    echo "==> 앱 공증"
    ditto -c -k --keepParent "$APP" "$OUT/Jjokview.zip"
    notarize "$OUT/Jjokview.zip"
    rm "$OUT/Jjokview.zip"
    xcrun stapler staple "$APP"
fi

echo "==> DMG"
STAGE=$OUT/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Jjokview.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Jjokview $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ $MODE != adhoc ]]; then
    IDENTITY=$(print -r -- "$SIGN_INFO" | sed -nE 's/^Authority=(Developer ID Application.*)$/\1/p' | head -1)
    codesign --sign "$IDENTITY" --timestamp --identifier dev.papig.jjokview.dmg "$DMG"
    echo "==> DMG 공증"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

shasum -a 256 "$DMG"
echo "완료: $DMG"
