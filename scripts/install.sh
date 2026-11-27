#!/bin/zsh
# Compila Ondas, la instala en ~/Applications y la abre desde ahí
# (así «Abrir al encender la Mac» apunta a una copia fija, no a la carpeta build).
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build-app.sh

DEST="$HOME/Applications/Ondas.app"
mkdir -p "$HOME/Applications"

# Cierra la copia que esté abierta y espera a que termine (máx. 5 s).
pkill -f "Ondas.app/Contents/MacOS/Ondas" 2>/dev/null || true
for _ in {1..25}; do
  pgrep -f "Ondas.app/Contents/MacOS/Ondas" >/dev/null || break
  sleep 0.2
done

rm -rf "$DEST"
cp -R build/Ondas.app "$DEST"
open "$DEST"
echo "Instalada en $DEST"
