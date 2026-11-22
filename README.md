# Ordexa

Manajer tugas pribadi dengan dasbor yang bersih dan terang. Aplikasi ini dirancang mengelilingi inti logika Zig yang dikompilasi menjadi WebAssembly. Lapisan peramban hanya menangani penyajian, interaksi form, dan penyimpanan setempat di peramban. Zig adalah bahasa terbesar dalam basis kode ini (lihat statistik bahasa GitHub).

## Fitur

- Buat, sunting, tandai selesai, dan hapus tugas
- Tenggat tanggal dan jam, tingkat kesulitan, kategori, serta catatan
- Statistik dasbor, grafik beban kerja kesulitan/tenggat, dan sebaran kategori
- Skor prioritas dihitung oleh inti Zig WebAssembly
- Pencarian, penyaringan, dan pengurutan
- Ekspor dan pemulihan cadangan JSON (di tampilan Pengaturan)
- Tata letak responsif untuk desktop, tablet, dan ponsel (diuji tanpa luapan horizontal pada 375–1440px)
- Tanpa basis data, akun, atau API eksternal
- PWA yang dapat dipasang: bekerja offline dengan service worker dan tembolok app-shell, plus navigasi bawah liquid-glass dengan indikator aktif yang meluncur mulus di ponsel
- Seluruh teks antarmuka berbahasa Indonesia dan hidup di dalam tabel string inti Zig
- Label tanggal, jam, dan tenggat ("Hari ini, 14.00", "3 hari lagi") diformat inti Zig — tanpa `Intl` peramban

## Tumpuan teknologi

- Zig 0.17.1: konversi tenggat, validasi, skor prioritas dan pitanya, klasifikasi urgensi, perhitungan penyelesaian, penyaringan tampilan (semua/hari ini/akan datang/selesai/aktif), pencocokan pencarian tanpa pedulikan besar-kecil, urutan tampil (prioritas/tenggat/dibuat), statistik ruang kerja, klasifikasi tenggat hari ini/besok, agregasi grafik beban kerja, sebaran kategori, penanda gaya baris tugas, kalender sipil proleptik Gregorian, format tanggal/jam/sisa-waktu Indonesia, perakitan HTML baris tugas (termasuk pengamanan HTML), tabel string UI berbahasa Indonesia, serta pemformat pesan ber-angka
- WebAssembly: menjalankan inti Zig di dalam peramban
- HTML/CSS/JavaScript murni: UI dan integrasi peramban
- `localStorage`: menyimpan tugas pada profil peramban saat ini
- Vercel: hosting statis

JavaScript sengaja dibatasi pada perenderan DOM, penanganan event, dan adaptor `localStorage` peramban. Segala sesuatu yang termasuk logika perencanaan hidup di `src/core.zig`: konversi tenggat ke jam, validasi tugas, skor, pita prioritas, klasifikasi urgensi, statistik, penyaringan tampilan, pencocokan pencarian, urutan tampil, pemilihan daftar fokus, klasifikasi hari ini/besok, agregasi grafik, sebaran kategori, kalender dan format tanggal Indonesia, markup baris tugas, dan seluruh teks UI berbahasa Indonesia. Lapisan JavaScript menyiapkan masukan ke memori linear WebAssembly lalu merender hasilnya; ia tidak pernah menghitung skor, urutan, statistik, atau label mandiri. Tidak ada fallback skor kembar di JavaScript: pembuatan tugas diblokir bila inti Zig WebAssembly gagal dimuat.

## Statistik bahasa GitHub

GitHub Linguist menghitung `public/` (hasil salinan `scripts/build.sh`) sebagai duplikat JavaScript/HTML/CSS bila folder itu ikut ter-commit, sehingga persentase Zig tampak jauh lebih kecil dari kenyataan. Karena itu:

- `.gitignore` mengecualikan `public/`, `.zig-cache/`, `zig-out/` — folder itu adalah keluaran build dan Vercel membangunnya sendiri saat deploy.
- `.gitattributes` menandai `public/**` sebagai `linguist-generated` (cadangan bila pernah ter-commit), menandai `README.md` sebagai `linguist-documentation`, dan `.wasm`/ikon sebagai biner.

Bila repositori lama masih memuat hasil build, bersihkan sekali lalu dorong ulang:

```bash
git rm -r --cached public .zig-cache zig-out 2>/dev/null
git add -A
git commit -m "Keluarkan artefak build dari pelacakan git"
git push
```

Setelah itu diagram bahasa akan menampilkan Zig sebagai bahasa dominan (sekitar separuh basis kode; sisanya CSS antarmuka, lapisan JS tipis, dan HTML).

## Jalankan setempat

```bash
chmod +x scripts/*.sh
./scripts/dev.sh
```

Buka <http://127.0.0.1:4173>.

Jalankan pertama mengunduh arsip Zig 0.17.1 resmi bila `zig` belum ada di PATH, menjalankan unit test Zig, mengompilasi `src/core.zig` menjadi `public/ordexa-core.wasm`, memverifikasi ekspor WebAssembly dengan Node.js, lalu menyalin aset web ke `public/`. Anda bisa mengarahkan build ke kompiler yang telah terpasang dengan `ZIG_BIN=/path/ke/zig bash scripts/build.sh`.

Untuk membangun tanpa menjalankan server pratinjau:

```bash
./scripts/build.sh
```

Skrip build otomatis menjalankan unit test Zig dan smoke test ABI WebAssembly. Alur kerja GitHub Actions juga menjalankan build yang sama pada push dan pull request. Untuk menjalankannya terpisah:

```bash
zig test src/core.zig
node tests/wasm-smoke.mjs public/ordexa-core.wasm
```

## Deploy ke Vercel

1. Dorong folder proyek ke repositori GitHub.
2. Di Vercel, pilih **Add New → Project** lalu impor repositori tersebut.
3. Pakai pengaturan proyek berikut:
   - Framework Preset: **Other**
   - Build Command: `bash scripts/build.sh`
   - Output Directory: `public`
   - Install Command: biarkan kosong/bawaan (tidak ada dependensi npm)
4. Deploy. Skrip build mengunduh Zig 0.17.1 di lingkungan build, mengompilasi modul WebAssembly, dan menyalin situs statis ke `public/`.

Repositori juga memuat `vercel.json` dengan perintah build, direktori keluaran, serta header MIME/tembolok WebAssembly. Vercel menjalankan unit test Zig dan smoke test ABI WASM sebelum menerbitkan. Tidak ada variabel lingkungan yang dibutuhkan.

## Data dan privasi

Tugas disimpan di `localStorage` peramban dengan kunci `ordexa.tasks.v1`. Tidak ada data tugas yang dikirim ke server. Service worker hanya menembolok app-shell statis (HTML, CSS, JS, WebAssembly, ikon) untuk pemakaian offline; ia tidak pernah menyentuh data tugas. Artinya:

- Tugas tetap berada di profil peramban yang sama setelah situs ditutup dan dibuka kembali.
- Tugas tidak otomatis tersinkron antar perangkat atau peramban.
- Menghapus data situs/penyimpanan peramban menghapus tugas yang tersimpan setempat. Gunakan **Ekspor cadangan** secara rutin dan simpan berkas JSON unduhan di tempat aman. Tombol Impor dapat memulihkan cadangan; impor menggantikan daftar tugas saat ini setelah konfirmasi.
- Deployment Vercel bersifat statis; tidak menyediakan basis data awan bersama.

## Model prioritas

Inti Zig mengembalikan skor 0 sampai 100. Kesulitan menyumbang skor dasar (Ringan 18, Sedang 42, Berat 66); sisa waktu menyumbang skor urgensi. Tugas yang melewati tenggat menerima kontribusi urgensi maksimum. Inti Zig juga mengurutkan tugas menurut skor yang ia hitung; antarmuka hanya merender urutan itu.

Ini alat bantu perencanaan, bukan penilaian otomatis atas upaya nyata yang dibutuhkan. Anda tetap bebas memilih tingkat kesulitan sendiri.

## Struktur proyek

```text
ordexa/
├── src/
│   └── core.zig
├── web/
│   ├── index.html
│   ├── styles.css
│   ├── app.js
│   ├── favicon.svg
│   ├── manifest.webmanifest
│   ├── sw.js
│   ├── icons/
│   │   ├── icon-192.png
│   │   ├── icon-512.png
│   │   ├── icon-maskable-512.png
│   │   └── apple-touch-icon.png
│   └── screenshots/
│       ├── lebar-desktop.png
│       └── sempit-mobile.png
├── scripts/
│   ├── build.sh
│   └── dev.sh
├── tests/
│   └── wasm-smoke.mjs
├── .github/
│   └── workflows/ci.yml
├── docs/
│   ├── ARCHITECTURE.md
│   ├── ARCHITECTURE_AUDIT.md
│   └── PROGRESS.md
├── package.json
├── vercel.json
└── README.md
```
