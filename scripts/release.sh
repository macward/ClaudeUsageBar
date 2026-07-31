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

# El output se captura antes de filtrar en vez de encadenar `codesign | grep -q`: bajo
# `set -o pipefail`, el `grep -q` corta al primer match y le manda SIGPIPE a codesign, con lo
# que el pipeline devuelve 141 y la verificación falla justo cuando debería pasar.
SIGN_INFO="$(codesign -d --verbose=2 "$APP_PATH" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - --verbose=2 "$APP_PATH" 2>&1)"

grep -q "app-sandbox" <<<"$ENTITLEMENTS" \
  || { echo "ERROR: la app perdió el entitlement de sandbox"; exit 1; }
grep -q "flags=.*runtime" <<<"$SIGN_INFO" \
  || { echo "ERROR: falta hardened runtime, la notarización lo rechazaría"; exit 1; }
grep -q "Developer ID Application" <<<"$SIGN_INFO" \
  || { echo "ERROR: no está firmada con Developer ID"; exit 1; }

# --- Notarización de la app ----------------------------------------------
# La .app se notariza y se sella ANTES de entrar al DMG. Sellar únicamente el DMG deja la
# app sin ticket propio: Gatekeeper igual la acepta mientras haya red, pero una copia de la
# .app arrastrada fuera del DMG y llevada a una máquina sin conexión no tiene contra qué
# validar. Son dos vueltas a Apple en vez de una, y cubren ese caso.
#
# El zip se arma con `ditto -c -k --keepParent`, que es lo que pide Apple: preserva symlinks
# y metadata del bundle, cosa que `zip` a secas no garantiza y rompería la firma.
info "Notarizando la app (1 de 2)"
APP_ZIP="$BUILD_DIR/ClaudeUsageBar.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

info "Stapleando la app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# --- DMG -----------------------------------------------------------------
# El DMG se arma a partir de la app ya sellada, así que el ticket viaja adentro.
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

# --- Notarización del DMG ------------------------------------------------
# El contenedor se notariza aparte de la app: el sello tiene que estar pegado al archivo
# que la persona descarga, que es donde Gatekeeper lo busca al abrirlo.
info "Notarizando el DMG (2 de 2)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

info "Stapleando el DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# --- Verificación final --------------------------------------------------
# Se evalúa el DMG y, montándolo, también la app de adentro: es la única forma de
# comprobar que el ticket viajó dentro del contenedor y no solo pegado a la tapa.
info "Verificación Gatekeeper"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
if [[ -n "$MOUNT_POINT" ]]; then
  spctl --assess --type execute --verbose=2 "$MOUNT_POINT/ClaudeUsageBar.app"
  xcrun stapler validate "$MOUNT_POINT/ClaudeUsageBar.app" \
    || { hdiutil detach "$MOUNT_POINT" -quiet; echo "ERROR: la app dentro del DMG quedó sin ticket"; exit 1; }
  hdiutil detach "$MOUNT_POINT" -quiet
fi

info "Listo: $DMG_PATH"
