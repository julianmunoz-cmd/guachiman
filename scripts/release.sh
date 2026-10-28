#!/usr/bin/env bash
# Publica una versión: sube versión y tag, y actualiza la fórmula del tap.
# Uso: scripts/release.sh X.Y.Z   (DRY_RUN=1 solo valida e imprime)
set -euo pipefail

VERSION="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TAP_DIR="${TAP_DIR:-$REPO/../homebrew-tap}"
PLIST="$REPO/Info.plist"
TAG="v$VERSION"

die() { echo "error: $*" >&2; exit 1; }
# Ejecuta el comando, o solo lo imprime en DRY_RUN.
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

[ -n "$VERSION" ] || die "falta la versión. Uso: make release VERSION=x.y.z"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "versión inválida '$VERSION' (formato x.y.z)"
[ -d "$TAP_DIR" ] || die "no existe el tap en $TAP_DIR (define TAP_DIR)"
TAP_DIR="$(cd "$TAP_DIR" && pwd)"
FORMULA="$TAP_DIR/Formula/guachiman.rb"
[ -f "$FORMULA" ] || die "no existe $FORMULA"

[ "$DRY_RUN" = 1 ] && echo "== DRY_RUN: no se modifica nada =="

echo "== Validaciones =="
cd "$REPO"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "el tag $TAG ya existe localmente"
[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || die "el tag $TAG ya existe en origin"
[ -z "$(git status --porcelain)" ] || die "el árbol de guachiman tiene cambios sin commitear"
[ "$(git branch --show-current)" = main ] || die "guachiman debe estar en la rama main"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main no está al día con origin/main"

[ -z "$(git -C "$TAP_DIR" status --porcelain)" ] || die "el tap tiene cambios sin commitear"
[ "$(git -C "$TAP_DIR" branch --show-current)" = main ] || die "el tap debe estar en la rama main"
git -C "$TAP_DIR" fetch -q origin main
[ "$(git -C "$TAP_DIR" rev-parse HEAD)" = "$(git -C "$TAP_DIR" rev-parse origin/main)" ] || die "el tap no está al día con origin/main"
echo "ok"

echo "== Versión en Info.plist =="
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NEXT=$((BUILD + 1))
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$PLIST"

echo "== Tests =="
if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] make test"; else make test; fi

echo "== Commit, tag y push =="
run git add Info.plist
run git commit -m "chore: versión $VERSION"
run git tag -a "$TAG" -m "Guachiman $VERSION"
run git push origin main
run git push origin "$TAG"

echo "== Fórmula del tap =="
URL="https://github.com/xklbr/guachiman/archive/refs/tags/$TAG.tar.gz"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] curl -fsSL $URL | shasum -a 256"
  SHA="<sha256>"
else
  SHA=""
  for i in 1 2 3 4 5 6; do
    # Con pipefail, si curl falla no se acepta el hash de un cuerpo vacío.
    if SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"; then break; fi
    SHA=""
    echo "el tarball aún no está disponible, reintentando ($i/6)..."; sleep 5
  done
  [ -n "$SHA" ] || die "no se pudo descargar $URL"
fi
run sed -i '' -E "s|^( *url ).*|\\1\"$URL\"|; s|^( *sha256 ).*|\\1\"$SHA\"|" "$FORMULA"
run git -C "$TAP_DIR" add Formula/guachiman.rb
run git -C "$TAP_DIR" commit -m "feat: guachiman $VERSION"
run git -C "$TAP_DIR" push origin main

echo
if [ "$DRY_RUN" = 1 ]; then
  echo "Ensayo terminado: no se publicó nada. Quita DRY_RUN=1 para publicar."
  exit 0
fi
echo "Listo. Guachiman $VERSION publicado. Para actualizar:"
echo "  brew update && brew upgrade guachiman"
