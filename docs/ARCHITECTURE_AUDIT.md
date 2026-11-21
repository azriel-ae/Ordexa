# Audit Arsitektur Ordexa

Dokumen ini mengaudit pemisahan tanggung jawab antara inti Zig dan lapisan
peramban, lalu mencatat perubahan implementasi yang benar-benar dilakukan.
Audit dilakukan dengan membaca `src/core.zig`, `web/app.js`, `web/index.html`,
`web/styles.css`, `scripts/build.sh`, `vercel.json`, dan
`.github/workflows/ci.yml`, serta menghitung fungsi yang diekspor modul
WebAssembly (`grep -c "export fn" src/core.zig` = 36 ekspor).

## 1. Arsitektur yang ada

```text
Peramban
  index.html   struktur semantik (section, nav, dialog, label)
  styles.css   presentasi murni (token desain di :root, tanpa logika)
  app.js       adaptor peramban: event, DOM, localStorage, Notification API
  sw.js        tembolok app-shell (tidak menyentuh data tugas)
        |
        |  WebAssembly ABI (36 ekspor, memori linear + arena goresan 512 KB)
        v
src/core.zig  seluruh aturan bisnis deterministik + seluruh teks UI Indonesia
```

Tidak ada `build.zig` — kompilasi dilakukan `scripts/build.sh` dengan flag
eksplisit `wasm32-freestanding` dan daftar ekspor, karena targetnya modul
WebAssembly tunggal tanpa pustaka eksternal. CI (`.github/workflows/ci.yml`)
menjalankan alur build yang sama.

## 2. Tanggung jawab inti Zig (diukur dari ekspor dan fungsi internal)

| Kelompok | Fungsi Zig | Keterangan |
| --- | --- | --- |
| Validasi tugas | `ordexa_validate`, `ordexa_validate_ex` | putusan akhir form: panjang judul (byte UTF-8), tenggat valid; mengembalikan ID pesan kesalahan |
| Skor & urgensi | `ordexa_score`, `ordexa_priority_band`, `ordexa_urgency`, `ordexa_hours_left`, `analisaTugas` | skor 0–100 dari kesulitan + sisa waktu; terlambat = urgensi maksimum |
| Penyaringan & urutan | `ordexa_filter_sort`, `cocokTampilan`, `urutSebelum`, `urutIndeks` | tampilan semua/hari ini/akan datang/selesai + urutan prioritas/tenggat/dibuat |
| Pencarian | `ordexa_contains_lower` | pencocokan sub-string ASCII tanpa pedulikan besar-kecil |
| Statistik & analitik | `ordexa_stats`, `ordexa_chart`, `ordexa_category_stats`, `ordexa_completion_percent`, `ordexa_analyze` | agregasi dasbor, matriks grafik 3x3, sebaran kategori |
| Kalendar & format tanggal | `tanggalSipil`, `hariDariTanggal`, `pecahWaktuLokal`, `ordexa_format_deadline`, `ordexa_format_date_label`, `ordexa_format_relative`, `ordexa_format_input_deadline`, `ordexa_deadline_kind` | kalender Gregorian proleptik sendiri; label "Hari ini, 14.00" tanpa `Intl` |
| Perakitan presentasi tugas | `ordexa_render_task_row`, `ordexa_row_flags`, `ordexa_row_ptr` | membangun markup HTML baris tugas termasuk pengamanan (escaping) HTML di sisi Zig |
| Teks UI & pesan | `ordexa_string_ptr/len/count`, `ordexa_*_label_id`, `ordexa_format_message`, `ordexa_version_string` | seluruh label Indonesia hidup di tabel string Zig |
| Notifikasi | `ordexa_notify_scan`, `ordexa_notify_due_body`, `ordexa_notify_ptr` | memutuskan tugas mana yang layak diberi peringatan (ambang jam, sekali per tugas) dan merakit isi pesannya |

## 3. Tanggung jawab JavaScript (diukur dari daftar fungsi app.js)

- Pemuatan/penyimpanan `localStorage` (`muatTugas`, `simpanTugas`,
  `muatPengaturan`, `simpanPengaturan`, migrasi kunci lama `ztask.tasks.v1`).
- Penulisan masukan ke arena goresan WASM dan pembacaan hasil
  (`tulisGoresan`, `hitungUrutan`, `analisaSemua`, `zigStr`, `zigFormat`).
- Render hasil Zig ke DOM (`render`, `renderStatistik`, `renderGrafik`,
  `renderKategori`, `renderTugasFokus`, `barisTugas` — markup baris dikirim
  Zig, JS hanya `innerHTML`).
- Event, navigasi tampilan, modal, toast, fokus keyboard.
- API peramban: `Notification`, service worker, ekspor/impor `Blob`/`File`,
  posisi indikator navigasi bawah (`offsetLeft/offsetWidth` — pengukuran
  tata letak, bukan logika bisnis).

## 4. Logika tumpang-tindih yang teridentifikasi

1. **`normalisasiTugas` (JS) membatasi judul 120 karakter, memvalidasi
   `new Date(deadline)`, memetakan kategori lama, dan membatasi kesulitan
   1–3.** Ini sanitasi masukan penyimpanan (impor/migrasi), bukan putusan
   form; putusan form tetap melalui `ordexa_validate_ex`. Duplikasi ini
   disengaja agar data rusak dari berkas cadangan tidak pernah masuk
   penyimpanan. Bila aturan normalisasi berkembang (mis. bidang baru),
   kandidat pemindahan: ekspor `ordexa_normalize`.
2. **`kirimForm` memeriksa kosong-tidaknya judul/tenggat sebelum memanggil
   Zig** — hanya untuk memilih pesan kesalahan yang tepat; pemeriksaan penuh
   (panjang byte UTF-8, dsb.) tetap di `ordexa_validate_ex`, dan simpan
   diblokir bila Zig belum termuat.
3. **Beberapa string fallback `'—'`/teks bawaan di JS** saat modul WASM
   gagal dimuat — jalur gagal total, bukan jalur normal.

Ketiganya tidak memindahkan keputusan bisnis ke JavaScript: tidak ada skor,
urutan, statistik, atau label yang dihitung dua kali.

## 5. Perbaikan yang direkomendasikan (dan statusnya)

| Rekomendasi | Status |
| --- | --- |
| Pertahankan validasi form sepenuhnya di Zig | sudah berjalan |
| Naikkan normalisasi impor ke Zig bila skema data bertambah | ditunda — skema masih v1 dan stabil |
| Ganti warna arc progres yang di-hardcode di app.js dengan token CSS | **dilakukan** ronde ini |
| Perbaiki grid pengaturan meluap di tablet | **dilakukan** ronde ini |
| Dokumentasikan ABI notifikasi di ARCHITECTURE.md | **dilakukan** ronde ini |

## 6. Perubahan implementasi ronde ini (yang benar-benar diubah)

- `web/styles.css`: sistem token desain baru (Warm Ivory `#F5F3EE`, Deep
  Charcoal `#292D2D`, Muted Teal `#668985`, Soft Amber `#C49359`, Stone Gray
  `#D9D7CF`), tipografi Manrope, indikator cair `.bn-indicator`, dukungan
  `prefers-reduced-motion`, grid pengaturan satu kolom di tablet.
- `web/index.html`: tautan font Manrope, elemen `bn-indicator`, kelas simbol
  statistik semantik (`symbol-work/done/late`), `theme-color` baru.
- `web/app.js`: fungsi `perbaruiIndikatorBawah()` (pengukuran posisi saja),
  arc cincin progres memakai token CSS, tanpa perubahan logika bisnis.
- `web/favicon.svg`: ikon ke palet baru.
- `web/sw.js`: `CACHE_VERSION` dinaikkan ke `ordexa-v9`.
- `web/screenshots/`: dua tangkapan layar baru untuk manifest PWA.
- Tidak ada perubahan pada `src/core.zig`, ABI, atau aturan bisnis — 66 unit
  test Zig dan smoke test ABI tidak berubah dan tetap lolos.

## 7. Kesimpulan

Pemisahan tanggung jawab sudah sehat: seluruh aturan bisnis deterministik
(validasi, skor, urgensi, penyaringan, urutan, statistik, analitik, format
tanggal, teks UI, keputusan notifikasi) hidup di `src/core.zig`; JavaScript
adalah lapisan peramban tipis untuk DOM, event, dan API peramban. Rasio
dominasi diukur dari tanggung jawab, bukan sekadar baris kode — dan pada
ukuran itu Zig memang pemegang seluruh keputusan perencanaan.
