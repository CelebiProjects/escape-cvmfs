#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: TOKEN=<GITHUB_TOKEN> $0 [--force] [--set-latest] <ARTIFACT_ID>" >&2
  exit 2
}

FORCE=false
SET_LATEST=false
while (( $# )); do
  case "$1" in
    -f|--force) FORCE=true ;;
    --set-latest) SET_LATEST=true ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done

# Keep the old positional form for existing callers.
if (( $# == 2 )); then
  TOKEN="$1"
  ID="$2"
elif (( $# <= 1 )); then
  ID="${1:-${ID:-}}"
else
  usage
fi
[[ -n "${TOKEN:-}" && "${ID:-}" =~ ^[0-9]+$ ]] || usage

REPO="${CVMFS_REPO:-sw.escape.eu}"
MOUNTPOINT="/cvmfs/$REPO"
WORK="$(mktemp -d)"
TRANSACTION=false
cleanup() {
  status=$?
  if [[ "$status" -ne 0 && "$TRANSACTION" == true ]]; then
    cvmfs_server abort -f "$REPO" || true
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -fLsS \
  -H "Accept: application/vnd.github+json" \
  -H @- \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/vre-hub/escape-cvmfs/actions/artifacts/${ID}/zip" \
  -o "$WORK/artifact.zip"
unzip -q "$WORK/artifact.zip" -d "$WORK/artifact"

mapfile -t archives < <(find "$WORK/artifact" -type f -name 'yuki-*.tar.gz')
[[ "${#archives[@]}" -eq 1 ]] || { echo "ERROR: expected exactly one Yuki tarball." >&2; exit 1; }
ARCHIVE="${archives[0]}"
CHECKSUM="${ARCHIVE}.sha256"
[[ -f "$CHECKSUM" ]] || { echo "ERROR: missing checksum: $CHECKSUM" >&2; exit 1; }
read -r digest checked_name < "$CHECKSUM"
if [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ || "$checked_name" != "$(basename "$ARCHIVE")" ]]; then
  echo "ERROR: checksum must name the downloaded tarball." >&2
  exit 1
fi
printf '%s  %s\n' "$digest" "$ARCHIVE" | sha256sum --check --strict

LABEL="$(basename "$ARCHIVE")"
LABEL="${LABEL#yuki-}"
LABEL="${LABEL%.tar.gz}"
if [[ ! "$LABEL" =~ ^[A-Za-z0-9._+-]+$ || "$LABEL" == . || "$LABEL" == .. || "$LABEL" == latest ]]; then
  echo "ERROR: invalid release label: $LABEL" >&2
  exit 1
fi
TARGET="$MOUNTPOINT/yuki/$LABEL"

cvmfs_server transaction "$REPO"
TRANSACTION=true
if [[ -e "$TARGET" ]]; then
  [[ "$FORCE" == true ]] || { echo "ERROR: $TARGET already exists; use --force to replace it." >&2; exit 1; }
  rm -rf "$TARGET"
fi
mkdir -p "$TARGET"
tar -xzf "$ARCHIVE" -C "$TARGET"
chmod -R a+rX "$TARGET"
if [[ "$SET_LATEST" == true ]]; then
  ln -sfnT "$LABEL" "$MOUNTPOINT/yuki/latest"
fi
cvmfs_server publish "$REPO"
TRANSACTION=false

echo "Published Yuki $LABEL to $TARGET"
