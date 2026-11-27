#!/bin/zsh
# Compila Ondas y arma build/Ondas.app
#
# Firma: si defines ONDAS_SIGN_IDENTITY (por ejemplo, tu certificado "Apple Development"),
# macOS recuerda los permisos aunque vuelvas a compilar. Sin ella, firma ad hoc.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Ondas"
APP="build/Ondas.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ondas"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Si el código vino en un ZIP bajado de internet, quita sus marcas para que la firma no falle.
xattr -cr "$APP"

IDENTITY="${ONDAS_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier com.ondas.touchbar "$APP"
codesign --verify "$APP"
echo "Listo: $APP"
