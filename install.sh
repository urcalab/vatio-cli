#!/usr/bin/env bash
# Installs the Vatio CLI (https://github.com/urcalab/vatio-cli) for the
# current user. No git, gem, or brew required — only curl/tar and a Ruby
# >= 2.6 already on PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/urcalab/vatio-cli/main/install.sh | bash
#
set -euo pipefail

REPO="urcalab/vatio-cli"
VERSION="${VATIO_CLI_VERSION:-latest}"
INSTALL_DIR="${VATIO_CLI_HOME:-$HOME/.vatio-cli}"
BIN_DIR="${VATIO_CLI_BIN:-$HOME/.local/bin}"
MIN_RUBY="2.6.0"

if ! command -v ruby >/dev/null 2>&1; then
  echo "error: ruby not found on PATH. Vatio CLI needs Ruby >= ${MIN_RUBY}." >&2
  exit 1
fi

ruby_version=$(ruby -e 'print RUBY_VERSION')
if ! ruby -e "exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(\"${MIN_RUBY}\") ? 0 : 1)"; then
  echo "error: found Ruby ${ruby_version}, but Vatio CLI needs >= ${MIN_RUBY}." >&2
  exit 1
fi

if [ "$VERSION" = "latest" ]; then
  tag=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | ruby -rjson -e 'print JSON.parse(STDIN.read)["tag_name"]')
else
  tag="$VERSION"
fi

url="https://github.com/${REPO}/archive/refs/tags/${tag}.tar.gz"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Vatio CLI ${tag}..."
curl -fsSL "$url" -o "$tmp/vatio-cli.tar.gz"
tar -xzf "$tmp/vatio-cli.tar.gz" -C "$tmp"

src_dir=$(find "$tmp" -maxdepth 1 -type d -name 'vatio-cli-*')
if [ -z "$src_dir" ]; then
  echo "error: could not find extracted source under $tmp" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
target="$INSTALL_DIR/$tag"
rm -rf "$target"
cp -R "$src_dir" "$target"
chmod +x "$target/bin/vatio"
ln -sfn "$target" "$INSTALL_DIR/current"
ln -sf "$INSTALL_DIR/current/bin/vatio" "$BIN_DIR/vatio"

echo "Installed Vatio CLI ${tag} to ${target}"
echo "Linked ${BIN_DIR}/vatio"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "Add ${BIN_DIR} to your PATH, e.g.:"
    echo "  echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> ~/.zshrc"
    ;;
esac

echo
"$BIN_DIR/vatio" version
