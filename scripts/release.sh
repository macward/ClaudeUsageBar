#!/bin/bash
#
# Construye, firma, notariza y empaqueta ClaudeUsageBar como un DMG distribuible.
#
# Requisitos previos (una sola vez):
#   - Certificado "Developer ID Application" en el llavero.
#   - Perfil de notarización guardado:
#       xcrun notarytool store-credentials "notarytool" \
#         --apple-id <apple-id> --team-id AAL663Y363 --password <app-specific-password>
#
# Uso:  ./scripts/release.sh
#
# El resultado queda en dist/ClaudeUsageBar-<version>.dmg, ya notarizado y stapleado,
# de modo que abre sin advertencias de Gatekeeper incluso en una máquina sin red.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="ClaudeUsageBar/ClaudeUsageBar.xcodeproj"
SCHEME="ClaudeUsageBar"
TEAM_ID="AAL663Y363"
SIGN_IDENTITY="Developer ID Application: Maximiliano Ward (${TEAM_ID})"
NOTARY_PROFILE="notarytool"

BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/ClaudeUsageBar.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# --- Tests ---------------------------------------------------------------
# Se corren antes de firmar: notarizar una build rota cuesta varios minutos de ida y vuelta
# con el servicio de Apple, y el error recién aparecería del otro lado.
info "Corriendo tests"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' test \
  | grep -E "TEST SUCCEEDED|TEST FAILED|error:" || true

# --- Archive -------------------------------------------------------------
info "Archivando (Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  > "$BUILD_DIR/archive.log" 2>&1 || { tail -40 "$BUILD_DIR/archive.log"; exit 1; }

# --- Export --------------------------------------------------------------
cat > "$BUILD_DIR/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

info "Exportando con Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  > "$BUILD_DIR/export.log" 2>&1 || { tail -40 "$BUILD_DIR/export.log"; exit 1; }

APP_PATH="$EXPORT_DIR/ClaudeUsageBar.app"
VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
DMG_PATH="$DIST_DIR/ClaudeUsageBar-${VERSION}.dmg"

# La notarización rebota cualquier binario sin hardened runtime; verificarlo acá evita
# descubrirlo después de esperar el veredicto de Apple.
info "Verificando la firma"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements - --verbose=2 "$APP_PATH" 2>&1 | grep -q "app-sandbox" \
  || { echo "ERROR: la app perdió el entitlement de sandbox"; exit 1; }
codesign -d --verbose=2 "$APP_PATH" 2>&1 | grep -q "flags=.*runtime" \
  || { echo "ERROR: falta hardened runtime, la notarización lo rechazaría"; exit 1; }

# --- DMG -----------------------------------------------------------------
info "Armando el DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "ClaudeUsageBar" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" > /dev/null

codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

# --- Notarización --------------------------------------------------------
# Se notariza el DMG, no el .app: el sello queda pegado al archivo que el usuario
# descarga, que es donde Gatekeeper lo busca.
info "Enviando a notarizar (esto tarda unos minutos)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

info "Stapleando el sello"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# Comprobación final con la misma evaluación que hace Gatekeeper al abrirlo.
info "Verificación Gatekeeper"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

info "Listo: $DMG_PATH"
