#!/usr/bin/env bash
# Source this file to activate Celebi from CVMFS.

if [[ -n "${BASH_VERSION:-}" ]]; then
  _celebi_setup_source="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  # Zsh uses this expansion to find the path of the sourced script.
  # shellcheck disable=SC2296
  _celebi_setup_source="${(%):-%N}"
else
  _celebi_setup_source="$0"
fi
_celebi_root="$(cd "$(dirname "$_celebi_setup_source")" && pwd)"
_celebi_lcg_python="/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc13-opt/bin/python3"

if [[ -z "${CELEBI_PYTHONBIN:-}" ]]; then
  if [[ -x "$_celebi_lcg_python" ]]; then
    export CELEBI_PYTHONBIN="$_celebi_lcg_python"
  elif command -v python3.11 >/dev/null 2>&1; then
    CELEBI_PYTHONBIN="$(command -v python3.11)"
    export CELEBI_PYTHONBIN
  else
    echo "ERROR: Celebi requires Python 3.11; neither LCG 107 nor python3.11 was found." >&2
    unset _celebi_root _celebi_lcg_python
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
  fi
fi

if ! "$CELEBI_PYTHONBIN" -I -c 'import sys; sys.exit(sys.version_info[:2] != (3, 11))'; then
  echo "ERROR: Celebi requires Python 3.11; selected interpreter: $CELEBI_PYTHONBIN." >&2
  unset _celebi_root _celebi_lcg_python _celebi_setup_source
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

case ":${PATH}:" in
  *":${_celebi_root}/bin:"*) ;;
  *) export PATH="${_celebi_root}/bin:${PATH}" ;;
esac

_celebi_site="${_celebi_root}/lib/python3.11/site-packages"
case ":${PYTHONPATH:-}:" in
  *":${_celebi_site}:"*) ;;
  *) export PYTHONPATH="${_celebi_site}${PYTHONPATH:+:${PYTHONPATH}}" ;;
esac

export CELEBI_HOME="$_celebi_root"
CELEBI_VERSION="$(cat "${_celebi_root}/VERSION" 2>/dev/null || echo unknown)"
export CELEBI_VERSION

unset _celebi_root _celebi_lcg_python _celebi_site _celebi_setup_source
