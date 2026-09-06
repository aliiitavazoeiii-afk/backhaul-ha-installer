#!/usr/bin/env bash
set -o pipefail

CONTROLLER="/opt/xhttp-dual/controller.py"
PYTHON="/usr/bin/python3"

if [[ ! -f "$CONTROLLER" ]]; then
  echo "xhttp-dual controller not found: $CONTROLLER" >&2
  exit 1
fi

if [[ "${1:-}" == "status" ]]; then
  "$PYTHON" "$CONTROLLER" "$@" | awk '
  BEGIN {
    green="\033[1;32m"
    red="\033[1;31m"
    yellow="\033[1;33m"
    reset="\033[0m"
  }
  {
    gsub(/healthy=True/,  "healthy=" green "True" reset)
    gsub(/healthy=False/, "healthy=" red "False" reset)
    gsub(/healthy=None/,  "healthy=" yellow "None" reset)
    print
  }'
  exit ${PIPESTATUS[0]}
fi

exec "$PYTHON" "$CONTROLLER" "$@"
