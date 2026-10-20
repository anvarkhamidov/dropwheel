#!/bin/zsh
# Релиз Dropwheel: сборка, подпись Developer ID, нотаризация, DMG, лента Sparkle.
#
#   scripts/release.sh             собрать всё локально в dist/updates/<версия>/
#   scripts/release.sh --publish   то же + GitHub Release (создаёт репозиторий релизов, если его нет)
#
# Перед релизом поднимите MARKETING_VERSION и CURRENT_PROJECT_VERSION в project.yml:
# Sparkle сравнивает CURRENT_PROJECT_VERSION (CFBundleVersion), и без увеличения обновление не придёт.
#
# Нужно на машине: сертификат Developer ID Application, профиль notarytool «dropwheel-notary»,
# ключ Sparkle в связке ключей (аккаунт «dropwheel», создан generate_keys), xcodegen, gh.
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="Developer ID Application: Anvar Khamidov (27G8CZPDWA)"
NOTARY_PROFILE=dropwheel-notary
SPARKLE_ACCOUNT=dropwheel
REPO=anvarkhamidov/dropwheel
DD=build/DerivedData
APP=$DD/Build/Products/Release/Dropwheel.app
PUBLISH=${1:-}

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
[[ -n $VERSION && -n $BUILD ]] || { echo "нет версии в project.yml"; exit 1; }
OUT=dist/updates/$VERSION
DMG=$OUT/Dropwheel-$VERSION.dmg
echo "== Dropwheel $VERSION ($BUILD)"

if [[ $PUBLISH == --publish ]] && gh release view "v$VERSION" --repo $REPO >/dev/null 2>&1; then
  echo "релиз v$VERSION уже опубликован — поднимите версию"; exit 1
fi

echo "== сборка"
xcodegen generate >/dev/null
rm -rf $DD/Build/Products/Release
xcodebuild -project Dropwheel.xcodeproj -scheme Dropwheel -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath $DD build -quiet

echo "== подпись Sparkle и приложения"
# Вложенные программы Sparkle должны быть подписаны нашим Developer ID с hardened runtime,
# иначе нотаризация отклонит сборку. Порядок — изнутри наружу.
SP=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
sign() { codesign -f -s "$IDENTITY" -o runtime --timestamp "$@"; }
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Dropwheel/Dropwheel.entitlements "$APP"
codesign --verify --deep --strict "$APP"

notarize() {
  local out
  out=$(xcrun notarytool submit "$1" --keychain-profile $NOTARY_PROFILE --wait 2>&1)
  echo "$out" | tail -2
  if ! echo "$out" | grep -q "status: Accepted"; then
    local id=$(echo "$out" | sed -n 's/^ *id: //p' | head -1)
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile $NOTARY_PROFILE
    exit 1
  fi
}

echo "== нотаризация приложения"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/app.zip"
notarize "$TMP/app.zip"
xcrun stapler staple "$APP" >/dev/null

echo "== DMG"
mkdir -p "$TMP/dmg" "$OUT"
ditto "$APP" "$TMP/dmg/Dropwheel.app"
ln -s /Applications "$TMP/dmg/Applications"
cp scripts/dmg-readme.txt "$TMP/dmg/Как установить.txt"
rm -f "$DMG"
hdiutil create -volname Dropwheel -srcfolder "$TMP/dmg" -fs HFS+ -format UDZO -ov "$DMG" -quiet
sign "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG" >/dev/null
spctl -a -t open --context context:primary-signature "$DMG"

echo "== лента обновлений"
# В ленте одна запись — последняя версия: SUFeedURL указывает на releases/latest/download/appcast.xml.
$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --account $SPARKLE_ACCOUNT \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT"
grep -q "sparkle:edSignature" "$OUT/appcast.xml" || { echo "appcast без подписи EdDSA"; exit 1; }
cp "$DMG" dist/Dropwheel.dmg
echo "готово: $DMG, $OUT/appcast.xml"

[[ $PUBLISH == --publish ]] || { echo "не опубликовано (запустите с --publish)"; exit 0; }

echo "== GitHub Release"
if ! gh repo view $REPO >/dev/null 2>&1; then
  gh repo create $REPO --public --description "Конвертер файлов колесом для macOS: перетащите файл, нажмите Shift, выберите формат"
fi
# Dropwheel.dmg без версии — для постоянной ссылки «Скачать» в README (releases/latest/download/Dropwheel.dmg).
gh release create "v$VERSION" "$DMG" "dist/Dropwheel.dmg" "$OUT/appcast.xml" --repo $REPO \
  --title "Dropwheel $VERSION" --notes "Dropwheel $VERSION (сборка $BUILD). Установленные копии обновятся сами."
echo "опубликовано: https://github.com/$REPO/releases/tag/v$VERSION"
