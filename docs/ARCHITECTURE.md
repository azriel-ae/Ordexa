# Arsitektur Ordexa

## Tujuan desain

1. Menjaga aturan bisnis di Zig.
2. Membuat rilis pertama tanpa basis data dan dapat dipakai sebagai situs statis.
3. Menjadikan deployment ke Vercel berupa impor Git dengan build yang dapat direproduksi.
4. Menjaga antarmuka tetap aksesibel, responsif, terang, dan bebas emoji dekoratif.

## Alur waktu proses

```text
UI peramban (HTML/CSS/JS)
  ├── Masukan form dan penanganan event
  ├── Adaptor localStorage peramban
  ├── Menyiapkan data tugas ke memori linear WebAssembly
  ├── Merender hasil yang dikembalikan inti Zig
  └── Memanggil fungsi WebAssembly yang diekspor
          |
          v
     Inti Zig (src/core.zig)
       ├── Validasi masukan tugas (ordexa_validate, ordexa_validate_ex)
       ├── Konversi tenggat ke jam (ordexa_hours_left)
       ├── Skor prioritas kesulitan + tenggat (ordexa_score)
       ├── Pita prioritas dan keranjang urgensi
       ├── Statistik penyelesaian (ordexa_stats)
       ├── Penyaringan tampilan: semua/hari ini/akan datang/selesai/aktif (ordexa_filter_sort)
       ├── Pencocokan pencarian tanpa pedulikan besar-kecil (ordexa_contains_lower)
       ├── Urutan tampil: prioritas/tenggat/dibuat (ordexa_filter_sort)
       ├── Pemilihan daftar fokus (tugas aktif menurut skor)
       ├── Klasifikasi tenggat hari ini/besok (ordexa_deadline_kind)
       ├── Agregasi grafik beban kerja (ordexa_chart)
       ├── Penanda kelas CSS baris tugas (ordexa_row_flags)
       ├── Tabel string UI berbahasa Indonesia (ordexa_string_ptr/len)
       ├── Pemformat pesan ber-angka (ordexa_format_message)
       └── Pemindaian notifikasi tugas mepet + isi pesannya
            (ordexa_notify_scan, ordexa_notify_due_body)
```

## ABI mesin

Lapisan JavaScript tidak pernah menghitung nilai perencanaan. Sebagai gantinya ia meminjam arena goresan 512 KB di dalam modul WebAssembly (`ordexa_scratch_reset` dan `ordexa_scratch_alloc`), menyiapkan larik terketik dan string UTF-8 di sana, lalu membaca hasilnya kembali:

- `ordexa_analyze`: nilai massal per tugas (sisa jam, skor, pita, urgensi, terlambat).
- `ordexa_stats`: total ruang kerja (total, selesai, aktif, terlambat, persen penyelesaian).
- `ordexa_chart`: hitungan batang grafik per kelompok urgensi x tingkat kesulitan plus nilai maksimum.
- `ordexa_row_flags`: kelas CSS prioritas/tenggat dan penanda selesai dipadatkan menjadi satu bendera bit.
- `ordexa_filter_sort`: menerapkan hasil pencarian + penyaring tampilan, mengembalikan urutan tampil.
- `ordexa_contains_lower`: pencocokan sub-string ASCII tanpa pedulikan besar-kecil.
- `ordexa_deadline_kind`: klasifikasi hari ini/besok/nanti memakai offset UTC pemanggil.
- `ordexa_string_ptr`/`ordexa_string_len`/`ordexa_*_label_id`: alamat, panjang, dan ID label untuk teks UI berbahasa Indonesia yang hidup di dalam modul Zig.
- `ordexa_format_message`: memformat pesan templat ber-angka ({0}/{1}) ke penyangga internal.
- `ordexa_notify_scan`: memindai kunci tugas, memilih tugas aktif yang sisa waktunya sudah menyentuh ambang (atau terlanjur lewat), dan mengembalikan ID-nya — sekali per tugas.
- `ordexa_notify_due_body`: merakit isi pesan peringatan (judul tugas + sisa waktu + tenggat terformat) ke penyangga notifikasi.
- `ordexa_render_task_row`/`ordexa_row_ptr`: merakit markup HTML satu baris tugas (termasuk pengamanan HTML) di sisi Zig.

## Mengapa localStorage peramban

Produk awalnya perencana personal satu pengguna. `localStorage` memberi kegigihan data di peramban pengguna tanpa memperkenalkan basis data atau sistem akun sisi server. Ia spesifik per asal dan per profil peramban; bukan sinkronisasi awan. Pengguna dapat mengekspor cadangan JSON dan memulihkannya nanti; impor menggantikan daftar tugas saat ini setelah konfirmasi.

## Deployment Vercel

Situs dideploy sebagai aset statis. Perintah build Vercel menjalankan `scripts/build.sh`, yang menjalankan unit test Zig natif, mengompilasi `src/core.zig` untuk `wasm32-freestanding` dengan ekspor eksplisit, memeriksa ABI WebAssembly dengan Node.js, lalu menyalin aset `web/` (termasuk `web/screenshots/` untuk manifest PWA) ke `public/`. Vercel menyajikan berkas HTML, CSS, JS, dan WASM hasil dengan tipe konten `application/wasm` eksplisit.

Tidak ada server HTTP Zig yang berjalan lama dalam arsitektur ini. Ini disengaja: deployment statis lebih sederhana dan cocok dengan model hosting Vercel. Bila nanti data bersama antar perangkat ditambahkan, itu akan membutuhkan layanan penyimpanan jarak jauh yang gigih dan desain API terautentikasi.
