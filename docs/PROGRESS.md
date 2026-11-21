# Progres Ordexa

Catatan riwayat pengerjaan, terbaru di atas.

## 2026-11-21 — Penyempurnaan visual anti AI-slop (Editorial Minimal)

- Refinement menyeluruh tampilan agar terasa SaaS profesional: hapus blob
  latar ambient, seluruh glass effect di luar navigasi bawah, shadow kartu
  (`--shadow-card` dihapus), gradient dekoratif (kartu total, batang grafik,
  bar kategori, topbar), eyebrow kapital di 11 lokasi, label MENU, ikon
  simbol statistik, label sumbu Y grafik yang tidak bermakna, grafik batang
  di empty state, hover rotate/translateY. Laporan lengkap dengan tangkapan
  layar sebelum/sesudah: `docs/VISUAL_DESIGN_AUDIT.md`.
- Statistik dashboard menjadi strip editorial tanpa kartu (4 kolom dengan
  pemisah hairline; mobile 2×2); panel kategori melebar penuh (`grid-column:
  1 / -1`) menutup lubang komposisi di kolom kanan.
- Sistem radius menurut fungsi (12px panel / 14px modal / 8px kontrol /
  6px chip); bayangan terpusat ke satu `--shadow-pop` khusus elemen
  mengambang (modal, dropdown, drawer, toast, bottom nav, FAB).
- Badge kesulitan/prioritas/kategori keluar dari kapsul kapital; label form
  normal-case 11px; h1 ditenangkan (clamp 24–30px, weight 600); target
  sentuh tombol "···" mobile 27 → 34px; `--ink-mute` digelapkan ke #6a6f6d
  (kontras 4.61:1, WCAG AA).
- Liquid glass bottom nav dipertahankan utuh dan diverifikasi ulang (regang
  sx=1.309, posisi final presisi, reduced-motion instan, tersembunyi ≥768px).
- Tanpa perubahan logika Zig/ABI/CRUD — 66 unit test + smoke test lolos,
  seluruh fitur diuji ulang di browser nyata, luapan horizontal 0 pada
  320–1440px, SW cache dinaikkan ke ordexa-v12.

## 2026-11-21 — Perombakan UX writing & microcopy

- Audit menyeluruh seluruh teks yang terlihat pengguna (dashboard, daftar,
  modal, toast, validasi, konfirmasi, pengaturan, notifikasi, manifest PWA)
  dengan prinsip: jelas di atas kreatif, tanpa slogan, kata kerja jelas,
  satu istilah per konsep. Laporan lengkap: `docs/UX_WRITING_AUDIT.md`.
- Istilah "Ruang kerja" dihapus dari semua permukaan: label sidebar jadi
  "MENU", breadcrumb berakar "Ordexa", tampilan utama disebut "Dashboard"
  secara konsisten (sebelumnya "Ringkasan" di sidebar tetapi "Beranda" di
  bottom nav).
- Slogan dan kalimat puitis diganti deskripsi fungsional: "Beri ruang untuk
  yang penting." → "Ringkasan tugas Anda.", "Di mana waktu Anda pergi" →
  "Tugas per kategori", "Sedikit kemajuan lama-lama jadi banyak." →
  "Persentase tugas yang sudah selesai.", "Kerja bagus, teruskan" →
  "Dari seluruh tugas Anda", badge "LANGSUNG" dihapus (CSS-nya ikut dibuang).
- Pola toast diseragamkan "…berhasil …"; judul modal edit dipisah dari teks
  tombol ("Edit tugas" + "Simpan perubahan"); "mepet" diganti "mendekat"
  pada copy pengguna; sapaan "-mu" diseragamkan "Anda".
- Semua perubahan teks UI tetap di tabel string `src/core.zig` (ID dan ABI
  tidak berubah, hanya isi); fallback string `app.js`, teks statis
  `index.html`, dan `manifest.webmanifest` disinkronkan; unit test dan smoke
  test yang merujuk teks lama diperbarui (66/66 + ABI lolos).
- Verifikasi browser 390px & 1280px: nol teks lama tersisa di DOM; bug ID
  string judul modal edit (29 → 28) ditemukan dan diperbaiki saat uji.
- Cache service worker dinaikkan ke `ordexa-v11`.

## 2026-11-21 — Penyempurnaan desain & arsitektur Zig-first

**Desain visual (Liquid Glass + Editorial Productivity)**

- Palet lama yang didominasi hijau moss diganti sistem token terpusat:
  Warm Ivory `#F5F3EE` (latar), Deep Charcoal `#292D2D` (teks), Muted Teal
  `#668985` (aksen utama/progres positif), Soft Amber `#C49359` (tenggat
  mepet/perhatian), Stone Gray `#D9D7CF` (garis), Pure White (permukaan kaca).
- Merah kini eksklusif untuk terlambat/galat/destruktif; grafik memakai satu
  sistem warna semantik yang sama (keluarga teal untuk kesulitan, amber untuk
  perhatian, merah untuk terlambat).
- Tipografi: Fraunces + Instrument Sans diganti Manrope untuk seluruh
  antarmuka; `<em>` judul jadi aksen warna (Manrope tanpa huruf miring).
- Navigasi bawah ponsel: indikator cair `.bn-indicator` — pil kaca yang
  meluncur ke item aktif dengan easing pegas tertahan; hanya menganimasikan
  `transform`, tanpa pergeseran tata letak; target sentuh minimum 46px.
- `prefers-reduced-motion` dihormati global (animasi/transisi dimatikan).
- Ikon favicon dan warna tema (manifest + meta) mengikuti palet baru.
- Perbaiki bug lama: grid pengaturan meluap 106px di tablet (768px) — kini
  satu kolom di bawah 1050px.
- Arc cincin progres yang tadinya di-hardcode hijau di app.js kini memakai
  token CSS.

**Uji yang dijalankan (hasil nyata)**

- 66 unit test Zig natif: semua lolos.
- Smoke test ABI WebAssembly (`tests/wasm-smoke.mjs`): lolos.
- Build produksi `scripts/build.sh`: sukses, aset tersalin ke `public/`.
- Headless (Chromium): CRUD tugas (buat/tandai selesai/hapus), pencarian
  (1 hasil untuk "proposal"), pengurutan tenggat, ekspor JSON (blob berisi
  6 tugas, kunci lengkap), impor JSON (mengganti daftar, tugas impor muncul),
  indikator nav sejajar presisi dengan item aktif di 390px, tanpa error
  konsol.
- Tanpa luapan horizontal di 375/390/430/768/1024/1440px untuk tiga tampilan
  (ringkasan, daftar, pengaturan).
- Tangkapan layar manifest PWA diperbarui dengan desain baru.

**Arsitektur**

- Tidak ada perubahan ABI/logika bisnis; audit lengkap di
  `docs/ARCHITECTURE_AUDIT.md`.

## 2026-11-20 — Notifikasi, PWA, dan bug navigasi drawer

- Notifikasi harian ("Sudah buka Ordexa hari ini?") dan peringatan tugas
  mepet; keputusan pemindaian dan isi pesan di `src/core.zig`
  (`ordexa_notify_scan`, `ordexa_notify_due_body`) dengan unit test.
- Perbaiki drawer ponsel yang tidak bisa dinavigasi (scrim di `body`
  menelan ketukan; dipindah ke `.app-shell::after`).
- Manifest PWA dilengkapi screenshot, shortcut aplikasi, `lang`, `dir`,
  `display_override`, `launch_handler`.
- `.gitattributes` + `.gitignore` agar statistik bahasa GitHub jujur:
  `public/` adalah artefak build, Zig tampil dominan.

## 2026-11-20 — Menu Pengaturan & bahasa Indonesia penuh

- Kartu "Ruang kerja privat" dan avatar dihapus; ekspor/impor dipindah ke
  tampilan Pengaturan khusus.
- Seluruh teks UI dipindah ke tabel string inti Zig; komentar kode
  berbahasa Indonesia; inti Zig diperluas (skor, penyaringan, statistik,
  grafik, format tanggal, perakitan baris HTML).
