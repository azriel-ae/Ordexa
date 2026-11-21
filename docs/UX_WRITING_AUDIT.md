# Audit UX Writing Ordexa

Tanggal: 2026-11-21 · Lingkup: seluruh teks yang terlihat pengguna di
`web/index.html`, tabel string `src/core.zig`, `web/app.js`,
`web/manifest.webmanifest`, dan service worker.

## Prinsip bahasa yang diterapkan

1. **Jelas di atas kreatif** — heading menyebut fungsi, bukan metafora.
2. **Tanpa slogan** — kalimat yang tidak menambah informasi dihapus, bukan
   diganti slogan baru.
3. **Kata kerja jelas pada tombol** — "Tambah tugas", "Simpan perubahan",
   "Hapus", "Batal", "Ekspor cadangan", "Pilih berkas".
4. **Notifikasi menyampaikan hasil** — pola "Tugas berhasil …".
5. **Konsisten** — satu istilah untuk satu konsep di semua permukaan
   (sidebar, bottom nav, breadcrumb, modal, toast).
6. **Sapaan "Anda"** — bentuk "-mu" yang cenderung akrab/kasual diganti
   seragam menjadi "Anda".
7. **Istilah Inggris hanya yang memang lazim** — Dashboard (nama tampilan
   utama); sisanya Indonesia ("tenggat", "kategori", "kesulitan").

## Temuan dan perubahan istilah penting

### Navigasi dan struktur

| Lama | Baru | Alasan |
| --- | --- | --- |
| "RUANG KERJA" (label sidebar) | "MENU" | Netral, standar, tanpa istilah buatan |
| "Ruang kerja /" (breadcrumb) | "Ordexa /" | Akar breadcrumb jadi nama produk |
| "Ringkasan" (sidebar) vs "Beranda" (bottom nav) — dua nama untuk satu tampilan | "Dashboard" di keduanya | Konsisten; istilah yang diinstruksikan |
| "ORDEXA · EDISI PERSONAL" | "ORDEXA · v2.1" | "Edisi personal" terdengar dibuat-buat; versi faktual |

### Dashboard

| Lama | Baru |
| --- | --- |
| "RUANG KERJA PERSONAL ANDA" (eyebrow) | "DASHBOARD" |
| "Beri ruang untuk yang penting." (h1) | "Ringkasan tugas Anda." |
| "Tampilan jelas atas prioritas, kemajuan, dan apa yang berikutnya." | "Prioritas, progres, dan tugas berikutnya dalam satu tampilan." |
| Catatan statistik "Di seluruh ruang kerja Anda" | "Termasuk tugas yang selesai" (kini faktual) |
| "Masih ada di daftar Anda" | "Belum ditandai selesai" |
| "Kerja bagus, teruskan" | "Dari seluruh tugas Anda" (motivasi dihapus) |
| "Perlu perhatian Anda" | "Sudah melewati tenggat" |
| "KONSISTENSI" (eyebrow) | "PROGRES" |
| "Sedikit kemajuan lama-lama jadi banyak." | "Persentase tugas yang sudah selesai." |
| "Di mana waktu Anda pergi" (h2) | "Tugas per kategori" |
| "Peta prioritas" (h2) | "Distribusi prioritas" |
| "FOKUS ANDA" / "Tugas yang butuh perhatian" | "PRIORITAS" / "Prioritas teratas" |
| Badge "LANGSUNG" (live label) | Dihapus — dekorasi tanpa informasi (CSS `.live-label` ikut dihapus) |

### Tampilan daftar & empty state

| Lama | Baru |
| --- | --- |
| "Semua yang Anda rencanakan, dalam satu tempat." | "Cari, saring, dan urutkan seluruh tugas Anda." |
| "Tampilan fokus untuk yang jatuh tempo hari ini." | "Tugas yang jatuh tempo hari ini." |
| "Pantau apa yang menjadi prioritas berikutnya." | "Tugas aktif dengan tenggat di masa depan." |
| "Catatan pekerjaan yang sudah Anda rampungkan." | "Tugas yang sudah Anda selesaikan." |
| "Belum ada yang ditampilkan." | "Tidak ada tugas yang cocok." |
| "Coba tampilan lain atau tambahkan tugas baru." | "Ubah kata kunci pencarian atau tambahkan tugas baru." |
| "Daftar Anda bersih." | "Belum ada tugas." |
| "Tambahkan tugas pertama Anda dan prioritas akan muncul di sini." | "Tambahkan tugas untuk mulai memantau prioritas." |
| "Belum ada tugas aktif untuk divisualkan." | "Belum ada tugas aktif untuk ditampilkan." |
| "Cari tugas Anda..." (placeholder) | "Cari tugas..." |

### Tindakan & notifikasi

| Lama | Baru |
| --- | --- |
| Tombol "+ Tugas baru" | "+ Tambah tugas" |
| "Buat tugas" / "Buat tugas pertama" | "Tambah tugas" |
| "Tugas ditambahkan." dkk. | "Tugas berhasil ditambahkan." dkk. (pola "berhasil" konsisten) |
| "Berhasil mengimpor {0} tugas." | "{0} tugas berhasil diimpor." |
| "…tidak bisa dibatalkan." | "…tidak dapat dibatalkan." |
| "Detail tugas belum valid." | "Periksa kembali detail tugas." |
| "Mesin Zig belum siap…" | "Inti Zig belum siap…" (satu istilah: "inti") |
| "…atau periksa deployment." | "…Muat ulang halaman lalu coba lagi." (hilangkan jargon dev) |
| "Tenggat mepet" (judul notifikasi) | "Tenggat mendekat" |
| "Peringatan tugas mepet" | "Peringatan tenggat mendekat" |
| "„X" mepet — tinggal 2 jam lagi (tenggat Hari ini, 14.00)." | "„X" mendekati tenggat — tinggal 2 jam lagi (Hari ini, 14.00)." |
| Pengingat harian: "Ruang kerjamu sedang bersih. Catat satu rencana kecil untuk hari ini?" | "Belum ada tugas terjadwal. Tambahkan satu untuk hari ini?" |
| "Ada {0} tugas menunggu di Ordexa. Lihat mana yang jadi prioritasmu hari ini." | "Ada {0} tugas aktif di Ordexa. Yang mana yang dikerjakan lebih dulu?" |
| "…Mulai dari yang paling menekan yuk." | "…{1} di antaranya mendekati tenggat." |

### Pengaturan

| Lama | Baru |
| --- | --- |
| "Atur ruang kerja Anda." (h1) | "Pengaturan" |
| "Kelola cadangan data tugas dan ketahui kondisi mesin Ordexa." | "Kelola data tugas, notifikasi, dan status aplikasi." |
| "Ajakan harian … Seluruh rumus waktunya dihitung inti Zig." | "Pengingat harian dan peringatan tenggat. Hanya berjalan selama aplikasi terbuka." (info batasan lebih berguna daripada pujian teknis) |
| "Ordexa menyapa setiap hari pada jam pilihanmu, misalnya menanyakan sudah membuka Ordexa atau belum…" | "Notifikasi singkat setiap hari pada jam yang Anda pilih." |
| "MESIN ORDEXA" (eyebrow) | "STATUS APLIKASI" |
| "…ada di ruang kerja Anda." | "…ada di daftar tugas Anda." |
| "Nyalakan pengingat…" (aria) | "Aktifkan pengingat…" |

### Modal tugas

| Lama | Baru |
| --- | --- |
| "Buat tugas" (judul modal) | "Tambah tugas" |
| Judul modal edit = "Simpan perubahan" (teks tombol dipakai sebagai judul) | Judul "Edit tugas", tombol tetap "Simpan perubahan" (dipisah) |
| "Bentuk langkah Anda berikutnya dengan jelas." | "Lengkapi detail tugas di bawah." |
| "Tambahkan detail, tautan, atau hal apa pun yang perlu diingat..." | "Tambahkan detail atau tautan jika perlu." |
| "Tambah tugas baru" (aria tombol +) | "Tambah tugas" |

### Footer & meta

| Lama | Baru |
| --- | --- |
| "Dibuat untuk kerja yang berkualitas." (3 footer) | "Manajer tugas pribadi yang bekerja offline." (faktual) |
| Shortcut PWA "Tugas baru" | "Tambah tugas" |
| Label screenshot "peta prioritas" | "distribusi prioritas" |

## Halaman dan komponen yang diperbarui

- Sidebar (label, item nav, footer sidebar) dan bottom nav (label + aria).
- Topbar: breadcrumb.
- Dashboard: heading, subtitle, 4 kartu statistik, 3 panel, empty state.
- Tampilan daftar (semua/hari ini/akan datang/selesai): judul, subtitle,
  toolbar pencarian/urutan, empty state.
- Modal tambah/edit tugas: judul, deskripsi, placeholder, tombol.
- Toast 7 aksi (tambah, ubah, selesai, aktif, hapus, ekspor, impor).
- Konfirmasi hapus, pesan validasi form, status inti, halaman Pengaturan
  penuh (ekspor/impor, notifikasi, status).
- Isi notifikasi harian dan peringatan tenggat (string + templat Zig).
- `manifest.webmanifest` (shortcut, label screenshot).

## Bagian yang belum diubah beserta alasan

- **Judul notifikasi "Sudah buka Ordexa hari ini?"** dipertahankan —
  pendek, manusiawi, dan sesuai konteks pengingat; bukan slogan.
- **Istilah internal kode** (nama konstanta `M_NOTIF_HARIAN_MEPET`,
  `ambangMepet`, komentar, nama unit test) tidak diubah — tidak terlihat
  pengguna; menggantinya berisiko mengubah perilaku tanpa manfaat UI.
- **Komentar CSS yang menyebut "tenggat mepet"** dipertahankan —
  dokumentasi internal, bukan copy.
- **"DIDUKUNG ZIG" di footer** dipertahankan — faktual dan singkat.
- Tidak ada sistem i18n/translation keys terpisah; seluruh teks berbahasa
  Indonesia tunggal, jadi tidak ada struktur terjemahan yang perlu
  dijaga/dirusak. Struktur ID string Zig dipertahankan penuh (hanya isi
  teks yang berubah), sehingga ABI dan pemetaan `S` di `app.js` aman.

## Verifikasi

- `zig test src/core.zig`: 66/66 lolos (test yang merujuk teks lama
  diperbarui mengikuti copy baru).
- Smoke test ABI `tests/wasm-smoke.mjs` lolos.
- Pemeriksaan DOM di browser (390px & 1280px): tidak ada satu pun teks
  lama yang tersisa; modal, toast, konfirmasi hapus, empty state, dan
  empat subtitle tampilan daftar terverifikasi menampilkan copy baru.
- Bug yang ditemukan dan diperbaiki saat verifikasi: judul modal edit
  sempat memakai ID string yang salah (29 → "Hapus tugas"); diperbaiki ke
  ID 28 ("Edit tugas") dan diverifikasi ulang di browser.
- Versi cache service worker dinaikkan ke `ordexa-v11` agar pengguna
  lama tidak terjebak copy lama.
