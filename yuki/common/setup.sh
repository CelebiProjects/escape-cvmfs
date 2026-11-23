#!/usr/bin/env bash
# Source this file to activate Yuki's immutable runtime from CVMFS.

if [[ -n "${BASH_VERSION:-}" ]]; then
  _yuki_setup_source="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  # Zsh uses this expansion to find the path of the sourced script.
  # shellcheck disable=SC2296
  _yuki_setup_source="${(%):-%N}"
else
  _yuki_setup_source="$0"
fi
_yuki_root="$(cd "$(dirname "$_yuki_setup_source")" && pwd)"
_yuki_lcg_python="/cvmfs/sft.cern.ch/lcg/views/LCG_107/x86_64-el9-gcc13-opt/bin/python3"

if [[ -z "${YUKI_PYTHONBIN:-}" ]]; then
  if [[ -x "$_yuki_lcg_python" ]]; then
    export YUKI_PYTHONBIN="$_yuki_lcg_python"
  elif command -v python3.11 >/dev/null 2>&1; then
    YUKI_PYTHONBIN="$(command -v python3.11)"
    export YUKI_PYTHONBIN
  else
    echo "ERROR: Yuki requires Python 3.11; neither LCG 107 nor python3.11 was found." >&2
    unset _yuki_root _yuki_lcg_python
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
  fi
fi

if ! "$YUKI_PYTHONBIN" -I -c 'import sys; sys.exit(sys.version_info[:2] != (3, 11))'; then
  echo "ERROR: Yuki requires Python 3.11; selected interpreter: $YUKI_PYTHONBIN." >&2
  unset _yuki_root _yuki_lcg_python _yuki_setup_source
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

case ":${PATH}:" in
  *":${_yuki_root}/bin:"*) ;;
  *) export PATH="${_yuki_root}/bin:${PATH}" ;;
esac

_yuki_site="${_yuki_root}/lib/python3.11/site-packages"
case ":${PYTHONPATH:-}:" in
  *":${_yuki_site}:"*) ;;
  *) export PYTHONPATH="${_yuki_site}${PYTHONPATH:+:${PYTHONPATH}}" ;;
esac

export YUKI_HOME="$_yuki_root"
export YUKI_CVMFS_ROOT="$_yuki_root"
YUKI_VERSION="$(cat "${_yuki_root}/VERSION" 2>/dev/null || echo unknown)"
export YUKI_VERSION
export YUKIDIR="${YUKIDIR:-$HOME/.Yuki}"

unset _yuki_root _yuki_lcg_python _yuki_site _yuki_setup_source
