#!/usr/bin/env bash
# Server pratinjau setempat Ordexa: build dulu, lalu sajikan ./public.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
bash scripts/build.sh
PORT="${PORT:-4173}"
echo "Ordexa tersedia di http://127.0.0.1:${PORT}"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory public
