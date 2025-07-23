#!/bin/sh
# install.sh — install k2 from an extracted release archive (Linux / macOS).
#
# Run from inside the extracted archive (this script sits next to bin/ and lib/):
#   ./install.sh                 # -> ~/.k2, adds bin to PATH via your shell rc
#   K2_PREFIX=/opt/k2 ./install.sh
#   K2_NO_PATH=1 ./install.sh    # copy only, don't touch PATH
#
# k2 finds its standard library + linker relative to the k2 binary, so the whole
# install is just bin/ + lib/ kept together; K2_HOME is set as a robust fallback.
set -eu

prefix="${K2_PREFIX:-$HOME/.k2}"
src="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$src/bin/k2" ] && [ ! -f "$src/bin/k2" ]; then
    echo "error: run this from inside the extracted k2 archive (no bin/k2 next to install.sh)" >&2
    exit 1
fi

# 1. Copy the layout to $prefix (replacing any prior install).
echo "Installing k2 -> $prefix"
rm -rf "$prefix/bin" "$prefix/lib"
mkdir -p "$prefix"
cp -R "$src/bin" "$prefix/bin"
cp -R "$src/lib" "$prefix/lib"
chmod +x "$prefix/bin/k2" 2>/dev/null || true
for m in LICENSE-APACHE-2.0.txt LICENSE-GPLv3.txt NOTICE README.md VERSION.txt; do
    [ -f "$src/$m" ] && cp "$src/$m" "$prefix/" || true
done

# 2. PATH + K2_HOME via the shell rc (idempotent).
bin="$prefix/bin"
if [ "${K2_NO_PATH:-0}" != "1" ]; then
    case "${SHELL:-/bin/sh}" in
        *zsh)  rc="$HOME/.zshrc" ;;
        *bash) rc="$HOME/.bashrc" ;;
        *)     rc="$HOME/.profile" ;;
    esac
    touch "$rc"
    if grep -q 'K2_HOME=' "$rc" 2>/dev/null; then
        echo "PATH/K2_HOME already configured in $rc"
    else
        {
            printf '\n# added by k2 install.sh\n'
            printf 'export K2_HOME="%s"\n' "$prefix"
            printf 'export PATH="%s:$PATH"\n' "$bin"
        } >> "$rc"
        echo "Added k2 to PATH in $rc"
    fi
fi

ver=""
[ -f "$prefix/VERSION.txt" ] && ver="$(head -n1 "$prefix/VERSION.txt")"
echo ""
echo "k2 $ver installed. Open a new terminal (or 'source' your shell rc), then:  k2 version"
