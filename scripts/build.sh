#!/usr/bin/env bash
# Skrip build Ordexa: uji unit Zig, kompilasi ke WebAssembly, smoke test ABI,
# lalu salin aset web ke ./public untuk hosting statis (mis. Vercel).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ZIG_VERSION="0.17.1"

# Cari Zig 0.17.1: pakai ZIG_BIN bila diatur, lalu Zig sistem, lalu unduh resmi.
resolve_zig() {
  if [[ -n "${ZIG_BIN:-}" ]]; then
    [[ -x "$ZIG_BIN" ]] || { echo "ZIG_BIN tidak dapat dieksekusi: $ZIG_BIN" >&2; exit 1; }
    [[ "$("$ZIG_BIN" version)" == "$ZIG_VERSION" ]] || { echo "ZIG_BIN harus Zig ${ZIG_VERSION}." >&2; exit 1; }
    printf '%s\n' "$ZIG_BIN"
    return
  fi
  if command -v zig >/dev/null 2>&1; then
    local zig_sistem
    zig_sistem="$(command -v zig)"
    if [[ "$("$zig_sistem" version)" == "$ZIG_VERSION" ]]; then
      printf '%s\n' "$zig_sistem"
      return
    fi
    echo "Abaikan Zig sistem $("$zig_sistem" version); Ordexa membutuhkan ${ZIG_VERSION}." >&2
  fi

  local arsitektur zig_arch dir_sementara arsip dir_pasang
  arsitektur="$(uname -m)"
  case "$arsitektur" in
    x86_64|amd64) zig_arch="x86_64" ;;
    aarch64|arm64) zig_arch="aarch64" ;;
    *) echo "Arsitektur Linux tidak didukung: $arsitektur" >&2; exit 1 ;;
  esac

  dir_sementara="${TMPDIR:-/tmp}/ordexa-toolchain-${ZIG_VERSION}"
  arsip="${dir_sementara}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"
  dir_pasang="${dir_sementara}/zig-${zig_arch}-linux-${ZIG_VERSION}"
  mkdir -p "$dir_sementara"
  if [[ ! -x "${dir_pasang}/zig" ]]; then
    echo "Mengunduh Zig ${ZIG_VERSION} untuk ${zig_arch}..." >&2
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
      --output "$arsip"
    tar -xf "$arsip" -C "$dir_sementara"
  fi
  [[ -x "${dir_pasang}/zig" ]] || { echo "Instalasi Zig gagal." >&2; exit 1; }
  printf '%s\n' "${dir_pasang}/zig"
}

ZIG_BIN_TERSELESAI="$(resolve_zig)"
echo "Menggunakan Zig: $("$ZIG_BIN_TERSELESAI" version)"

# 1) Uji unit inti Zig.
"$ZIG_BIN_TERSELESAI" test src/core.zig

# 2) Kompilasi inti ke WebAssembly (freestanding, tanpa entry point).
mkdir -p public
"$ZIG_BIN_TERSELESAI" build-exe src/core.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  --export-memory \
  --export=ordexa_hours_left \
  --export=ordexa_score \
  --export=ordexa_priority_band \
  --export=ordexa_urgency \
  --export=ordexa_validate \
  --export=ordexa_validate_ex \
  --export=ordexa_completion_percent \
  --export=ordexa_deadline_kind \
  --export=ordexa_string_count \
  --export=ordexa_string_ptr \
  --export=ordexa_string_len \
  --export=ordexa_difficulty_label_id \
  --export=ordexa_priority_label_id \
  --export=ordexa_kind_label_id \
  --export=ordexa_format_ptr \
  --export=ordexa_format_message \
  --export=ordexa_scratch_reset \
  --export=ordexa_scratch_alloc \
  --export=ordexa_contains_lower \
  --export=ordexa_analyze \
  --export=ordexa_stats \
  --export=ordexa_chart \
  --export=ordexa_row_flags \
  --export=ordexa_filter_sort \
  --export=ordexa_format_deadline \
  --export=ordexa_format_date_label \
  --export=ordexa_format_relative \
  --export=ordexa_format_input_deadline \
  --export=ordexa_render_task_row \
  --export=ordexa_row_ptr \
  --export=ordexa_category_stats \
  --export=ordexa_category_label_id \
  --export=ordexa_version_string \
  --export=ordexa_notify_scan \
  --export=ordexa_notify_due_body \
  --export=ordexa_notify_ptr \
  -femit-bin=public/ordexa-core.wasm

[[ -s public/ordexa-core.wasm ]] || { echo "Keluaran WebAssembly hilang atau kosong." >&2; exit 1; }

# 3) Smoke test ABI lewat Node.js.
command -v node >/dev/null 2>&1 || { echo "Node.js dibutuhkan untuk smoke test ABI WebAssembly." >&2; exit 1; }
node tests/wasm-smoke.mjs public/ordexa-core.wasm

# 4) Salin aset web statis.
cp web/index.html public/index.html
cp web/styles.css public/styles.css
cp web/app.js public/app.js
cp web/favicon.svg public/favicon.svg
cp web/manifest.webmanifest public/manifest.webmanifest
cp web/sw.js public/sw.js
mkdir -p public/icons
cp web/icons/*.png public/icons/
mkdir -p public/screenshots
cp web/screenshots/*.png public/screenshots/

echo "Aset produksi Ordexa siap di ./public"
