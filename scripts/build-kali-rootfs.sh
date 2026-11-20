#!/usr/bin/env bash
# The workflow "build-kali-a2corelte" calls this script. It now builds the ALL-IN-ONE zip
# (Kali + touch desktop, written to the whole internal storage, flashed from the microSD card).
# The previous version of this script is in the git history.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash scripts/build-aio.sh
