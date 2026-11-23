#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${CELEBI_SOURCE_DIR:-}"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"

if [[ -z "$SOURCE_DIR" || ! -f "$SOURCE_DIR/pyproject.toml" ]]; then
  echo "ERROR: set CELEBI_SOURCE_DIR to a Celebi source checkout." >&2
  exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
if ! "$PYTHON_BIN" -I -c 'import sys; sys.exit(sys.version_info[:2] != (3, 11))'; then
  echo "ERROR: CVMFS build requires Python 3.11 ($PYTHON_BIN)." >&2
  exit 1
fi
VERSION="$("$PYTHON_BIN" - "$SOURCE_DIR/pyproject.toml" <<'PY'
import pathlib, sys, tomllib
print(tomllib.loads(pathlib.Path(sys.argv[1]).read_text())["project"]["version"])
PY
)"
COMMIT="$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD)"
LABEL="${CELEBI_LABEL:-${VERSION}-${COMMIT}}"
[[ "$LABEL" =~ ^[A-Za-z0-9._+-]+$ && "$LABEL" != . && "$LABEL" != .. && "$LABEL" != latest ]] || { echo "ERROR: invalid release label: $LABEL" >&2; exit 1; }
BUILD_ROOT="$SCRIPT_DIR/build-${LABEL}"
SITE_PACKAGES="$BUILD_ROOT/lib/python3.11/site-packages"
ARCHIVE="$SCRIPT_DIR/celebi-${LABEL}.tar.gz"

rm -rf "$BUILD_ROOT"
mkdir -p "$SITE_PACKAGES" "$BUILD_ROOT/bin"

"$PYTHON_BIN" -m pip install --disable-pip-version-check --no-cache-dir \
  --target "$SITE_PACKAGES" "$SOURCE_DIR"

"$PYTHON_BIN" -m pip list --path "$SITE_PACKAGES" --format=freeze > "$BUILD_ROOT/PACKAGE_VERSIONS"

if [[ -d "$SITE_PACKAGES/bin" ]]; then
  cp -a "$SITE_PACKAGES/bin/." "$BUILD_ROOT/bin/"
  rm -rf "${SITE_PACKAGES:?}/bin"
fi

# Generate launchers from wheel metadata. pip --target does not preserve
# the scripts directory on every Python sysconfig layout (including LCG).
"$PYTHON_BIN" - "$SITE_PACKAGES" "$BUILD_ROOT/bin" celebi celebi-cli celebi-git <<'PYCODE'
from importlib.metadata import distributions
from pathlib import Path
import sys

site, bin_dir, *commands = sys.argv[1:]
dist = next(
    (item for item in distributions(path=[site])
     if item.metadata["Name"].lower() == "celebichrono"),
    None,
)
if dist is None:
    sys.exit("ERROR: CelebiChrono wheel metadata is missing")
registered = {ep.name: ep for ep in dist.entry_points if ep.group == "console_scripts"}
for command in commands:
    if command not in registered:
        sys.exit(f"ERROR: missing console entry point: {command}")
    module, attribute = registered[command].value.split(":", 1)
    (Path(bin_dir) / (command + ".py")).write_text(
        "import sys\n"
        "from importlib import import_module\n"
        "sys.argv[0] = sys.argv[0].removesuffix('.py')\n"
        f"entry = import_module({module!r})\n"
        f"for attribute in {attribute!r}.split('.'):\n"
        "    entry = getattr(entry, attribute)\n"
        "sys.exit(entry())\n"
    )
PYCODE

for entrypoint in celebi celebi-cli celebi-git; do
  cat > "$BUILD_ROOT/bin/$entrypoint" <<'SH'
#!/usr/bin/env bash
exec "${CELEBI_PYTHONBIN:?Source setup.sh first}" "$0.py" "$@"
SH
  chmod +x "$BUILD_ROOT/bin/$entrypoint"
done

cp "$SCRIPT_DIR/common/setup.sh" "$BUILD_ROOT/setup.sh"
printf '%s\n' "$LABEL" > "$BUILD_ROOT/VERSION"
printf '%s\n' "$COMMIT" > "$BUILD_ROOT/SOURCE_COMMIT"

tar -czf "$ARCHIVE" -C "$BUILD_ROOT" .
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$SCRIPT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
else
  (cd "$SCRIPT_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
fi

echo "Built $ARCHIVE"
