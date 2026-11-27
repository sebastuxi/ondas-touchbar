#!/bin/zsh
# Arma build/Ondas.zip para publicar: app universal (Intel y Apple Silicon) con firma ad hoc,
# para que no lleve el nombre de tu certificado.
set -euo pipefail
cd "${0:A:h}/.."

ONDAS_UNIVERSAL=1 ONDAS_SIGN_IDENTITY=- ./scripts/build-app.sh
echo "Arquitecturas: $(lipo -archs build/Ondas.app/Contents/MacOS/Ondas)"

rm -f build/Ondas.zip
ditto -c -k --keepParent build/Ondas.app build/Ondas.zip
echo "Listo: build/Ondas.zip"
