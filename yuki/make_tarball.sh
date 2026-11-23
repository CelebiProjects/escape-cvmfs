#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YUKI_SOURCE="${YUKI_SOURCE_DIR:-}"
CELEBI_SOURCE="${CELEBI_SOURCE_DIR:-}"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
CONDA_BIN="${CONDA_BIN:-conda}"
CONDA_PACK_BIN="${CONDA_PACK_BIN:-conda-pack}"
RABBITMQ_VERSION="${RABBITMQ_VERSION:-4.2.5}"

if [[ -z "$YUKI_SOURCE" || ! -f "$YUKI_SOURCE/pyproject.toml" ]]; then
  echo "ERROR: set YUKI_SOURCE_DIR to a Yuki source checkout." >&2
  exit 1
fi
if [[ -z "$CELEBI_SOURCE" || ! -f "$CELEBI_SOURCE/pyproject.toml" ]]; then
  echo "ERROR: set CELEBI_SOURCE_DIR to the matching Celebi source checkout." >&2
  exit 1
fi

YUKI_SOURCE="$(cd "$YUKI_SOURCE" && pwd)"
CELEBI_SOURCE="$(cd "$CELEBI_SOURCE" && pwd)"
if ! "$PYTHON_BIN" -I -c 'import sys; sys.exit(sys.version_info[:2] != (3, 11))'; then
  echo "ERROR: CVMFS build requires Python 3.11 ($PYTHON_BIN)." >&2
  exit 1
fi
VERSION="$("$PYTHON_BIN" - "$YUKI_SOURCE/pyproject.toml" <<'PY'
import pathlib, sys, tomllib
print(tomllib.loads(pathlib.Path(sys.argv[1]).read_text())["project"]["version"])
PY
)"
YUKI_COMMIT="$(git -C "$YUKI_SOURCE" rev-parse --short=12 HEAD)"
CELEBI_COMMIT="$(git -C "$CELEBI_SOURCE" rev-parse --short=12 HEAD)"
LABEL="${YUKI_LABEL:-${VERSION}-${YUKI_COMMIT}}"
[[ "$LABEL" =~ ^[A-Za-z0-9._+-]+$ && "$LABEL" != . && "$LABEL" != .. && "$LABEL" != latest ]] || { echo "ERROR: invalid release label: $LABEL" >&2; exit 1; }
BUILD_ROOT="$SCRIPT_DIR/build-${LABEL}"
SITE_PACKAGES="$BUILD_ROOT/lib/python3.11/site-packages"
ARCHIVE="$SCRIPT_DIR/yuki-${LABEL}.tar.gz"
CVMFS_PREFIX="${YUKI_CVMFS_PREFIX:-/cvmfs/sw.escape.eu/yuki/${LABEL}}"
RUNTIME_WORK="$(mktemp -d)"
RUNTIME_WORK="$(cd "$RUNTIME_WORK" && pwd -P)"
RUNTIME_ARCHIVE="$RUNTIME_WORK/rabbitmq-runtime.tar.gz"
cleanup() {
  rm -rf "$RUNTIME_WORK"
}
trap cleanup EXIT

RUNTIME_DEST="$CVMFS_PREFIX/lib/rabbitmq"
# Conda-pack cannot grow a binary prefix past the space available at build time.
destination_bytes="$(LC_ALL=C printf '%s' "$RUNTIME_DEST" | wc -c)"
RUNTIME_PREFIX="$RUNTIME_WORK/env"
while (( $(LC_ALL=C printf '%s' "$RUNTIME_PREFIX" | wc -c) < destination_bytes )); do
  RUNTIME_PREFIX="$RUNTIME_PREFIX/conda-pack-build-prefix-padding"
done

rm -rf "$BUILD_ROOT"
mkdir -p "$SITE_PACKAGES" "$BUILD_ROOT/bin"

# REANA can depend on Snakemake 7 to validate workflow definitions. Yuki
# launches its native Snakemake version as a separate CLI process.
"$PYTHON_BIN" - "$YUKI_SOURCE/pyproject.toml" "$RUNTIME_WORK" <<'PY'
from pathlib import Path
import re
import sys
import tomllib

project, work = map(Path, sys.argv[1:])
dependencies = tomllib.loads(project.read_text())["project"].get("dependencies", [])
service, native = [], []
for requirement in dependencies:
    name = re.match(r"[a-zA-Z0-9_.-]+", requirement).group()
    (native if name.lower() == "snakemake" else service).append(requirement)
for name, requirements in (("service", service), ("native", native)):
    (work / (name + ".txt")).write_text("".join(req + "\n" for req in requirements))
PY

"$PYTHON_BIN" -m pip install --disable-pip-version-check --no-cache-dir \
  --target "$SITE_PACKAGES" -r "$RUNTIME_WORK/service.txt" "$CELEBI_SOURCE"
"$PYTHON_BIN" -m pip install --disable-pip-version-check --no-cache-dir --no-deps \
  --target "$RUNTIME_WORK/yuki-package" "$YUKI_SOURCE"
cp -a "$RUNTIME_WORK/yuki-package/." "$SITE_PACKAGES/"

if [[ -s "$RUNTIME_WORK/native.txt" ]]; then
  NATIVE_SITE="$BUILD_ROOT/lib/snakemake"
  "$PYTHON_BIN" -m pip install --disable-pip-version-check --no-cache-dir \
    --target "$NATIVE_SITE" -r "$RUNTIME_WORK/native.txt"
  "$PYTHON_BIN" -m pip list --path "$NATIVE_SITE" --format=freeze > "$BUILD_ROOT/NATIVE_PACKAGE_VERSIONS"
fi

"$PYTHON_BIN" -m pip list --path "$SITE_PACKAGES" --format=freeze > "$BUILD_ROOT/PACKAGE_VERSIONS"

command -v "$CONDA_BIN" >/dev/null 2>&1 \
  || { echo "ERROR: conda/mamba is required to package RabbitMQ." >&2; exit 1; }
command -v "$CONDA_PACK_BIN" >/dev/null 2>&1 \
  || { echo "ERROR: conda-pack is required to package RabbitMQ." >&2; exit 1; }

RABBITMQ_SPEC="rabbitmq-server==$RABBITMQ_VERSION"
"$CONDA_BIN" create --yes --prefix "$RUNTIME_PREFIX" \
  --override-channels --channel conda-forge "$RABBITMQ_SPEC"
"$CONDA_PACK_BIN" --prefix "$RUNTIME_PREFIX" \
  --output "$RUNTIME_ARCHIVE" \
  --dest-prefix "$RUNTIME_DEST"
mkdir -p "$BUILD_ROOT/lib/rabbitmq"
tar -xzf "$RUNTIME_ARCHIVE" -C "$BUILD_ROOT/lib/rabbitmq"
if [[ -d "$BUILD_ROOT/lib/rabbitmq/lib/erlang" ]]; then
  ln -s rabbitmq/lib/erlang "$BUILD_ROOT/lib/erlang"
fi

if [[ -d "$SITE_PACKAGES/bin" ]]; then
  cp -a "$SITE_PACKAGES/bin/." "$BUILD_ROOT/bin/"
  rm -rf "${SITE_PACKAGES:?}/bin"
fi

# Generate launchers from wheel metadata. pip --target does not preserve
# the scripts directory on every Python sysconfig layout (including LCG).
"$PYTHON_BIN" - "$SITE_PACKAGES" "$BUILD_ROOT/bin" yuki yukirunner yuki-create-data yuki-native-runner <<'PYCODE'
from importlib.metadata import distributions
from pathlib import Path
import sys

site, bin_dir, *commands = sys.argv[1:]
dist = next(
    (item for item in distributions(path=[site])
     if item.metadata["Name"].lower() == "yuki"),
    None,
)
if dist is None:
    sys.exit("ERROR: Yuki wheel metadata is missing")
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

for entrypoint in yuki yukirunner yuki-create-data yuki-native-runner; do
  cat > "$BUILD_ROOT/bin/$entrypoint" <<'SH'
#!/usr/bin/env bash
exec "${YUKI_PYTHONBIN:?Source setup.sh first}" "$0.py" "$@"
SH
  chmod +x "$BUILD_ROOT/bin/$entrypoint"
done

if [[ -s "$RUNTIME_WORK/native.txt" ]]; then
  cat > "$BUILD_ROOT/bin/snakemake" <<'SH'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONPATH="$root/lib/snakemake"
export PYTHONNOUSERSITE=1
exec "${YUKI_PYTHONBIN:?Source setup.sh first}" -m snakemake "$@"
SH
  chmod +x "$BUILD_ROOT/bin/snakemake"
fi

cp "$SCRIPT_DIR/common/yuki-service" "$BUILD_ROOT/bin/yuki-service"
cp "$SCRIPT_DIR/common/rabbitmq-server" "$BUILD_ROOT/bin/rabbitmq-server"
cp "$SCRIPT_DIR/common/rabbitmqctl" "$BUILD_ROOT/bin/rabbitmqctl"
chmod +x "$BUILD_ROOT/bin/yuki-service" \
  "$BUILD_ROOT/bin/rabbitmq-server" "$BUILD_ROOT/bin/rabbitmqctl"
cp "$SCRIPT_DIR/common/setup.sh" "$BUILD_ROOT/setup.sh"
printf '%s\n' "$LABEL" > "$BUILD_ROOT/VERSION"
{
  printf 'yuki %s\n' "$YUKI_COMMIT"
  printf 'celebi %s\n' "$CELEBI_COMMIT"
} > "$BUILD_ROOT/SOURCE_COMMIT"
"$CONDA_BIN" list --prefix "$RUNTIME_PREFIX" > "$BUILD_ROOT/RABBITMQ_PACKAGES"

tar -czf "$ARCHIVE" -C "$BUILD_ROOT" .
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$SCRIPT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
else
  (cd "$SCRIPT_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
fi

echo "Built $ARCHIVE"
