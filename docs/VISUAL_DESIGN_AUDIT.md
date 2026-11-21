# Audit Visual Ordexa — Anti AI-Slop Refinement

Tanggal: 2026-11-21 · Lingkup: `web/styles.css`, `web/index.html`, satu baris
template presentasi di `web/app.js`, versi cache service worker.
Tidak ada perubahan logika bisnis, ABI WebAssembly, penyimpanan data, CRUD,
perhitungan prioritas, atau sistem navigasi.

## 1. Masalah visual yang ditemukan (kondisi "before")

Audit awal terhadap seluruh design token dan hasil tangkapan layar
(1440px dan 390px) menemukan ciri khas desain hasil generate AI:

1. **Latar ambient dekoratif** — `.backdrop-decor` menempelkan tiga blob
   blur 90px warna sage/peach/stone di belakang seluruh aplikasi; pada
   desktop menghasilkan noda kelabu-zaitun keruh di kuadran kanan atas
   tanpa fungsi apa pun.
2. **Glass effect menyebar ke mana-mana** — `backdrop-filter` aktif pada
   sidebar, topbar, tombol ikon, dropdown menu baris, modal, drawer, dan
   toast, padahal liquid glass seharusnya ciri khusus navigasi bawah.
3. **Shadow berlapis-lapis** — `--shadow-card` dipasang pada setiap kartu,
   kotak cari, dan select; tombol utama memakai inset highlight + drop
   shadow berwarna; FAB memakai tiga lapis bayangan.
4. **Gradient dekoratif** — kartu "Total tugas" (teal→putih), tiga seri
   batang grafik (gradient vertikal per batang), bar kategori (teal→teal),
   topbar (diagonal putih), plus garis "kilau spekular" di topbar.
5. **Terlalu banyak card identik** — 4 kartu statistik + 4 panel besar,
   semuanya kotak putih radius 16px yang sama; hierarki dibedakan hanya
   oleh eyebrow 9.5px kapital spasi-lebar.
6. **Lubang komposisi** — panel kategori hanya menempati kolom pertama
   grid dua kolom, menyisakan area kosong besar di sebelah kanannya.
7. **Label sumbu grafik palsu** — "Tinggi/Sedang/Rendah" di sumbu Y tidak
   berkorespondensi dengan garis kisi 25% mana pun.
8. **Pill & uppercase berlebihan** — badge kesulitan/prioritas kapsul
   penuh kapital spasi-lebar; eyebrow, footer, dan label MENU semuanya
   kapital kecil ber-tracking lebar.
9. **Hover gimmick** — tombol ikon pengaturan berputar 28° saat hover;
   tombol utama mengangkat diri (translateY) plus bayangan.
10. **Teks sekunder di bawah ambang kontras** — `--ink-mute #7b8281`
    hanya 3.54:1 di atas Warm Ivory (WCAG AA menuntut 4.5:1).

## 2. Elemen yang dihilangkan (remove before adding)

| Elemen | Alasan |
| --- | --- |
| `.backdrop-decor` (3 blob blur) + seluruh CSS-nya | Dekorasi murni, menciptakan noda keruh |
| Eyebrow kapital di 11 lokasi (DASHBOARD, PROGRES, PRIORITAS, …) | Mengulang hierarki yang sudah dibawa h2/h1; uppercase berlebihan |
| Label "MENU" di sidebar (`workspace-label`) | Sidebar sudah jelas menu; label menambah derau |
| Ikon simbol statistik (▤ ◷ ✓ !) dan kelas `stat-symbol`/`symbol-*` | Redundan dengan label + angka; "!" duplikat semantik merah |
| Label sumbu Y grafik (Tinggi/Sedang/Rendah) + `chart-y-labels` | Tidak berkorespondensi dengan skala apa pun |
| Grafik batang mini di empty state (`empty-graphic`, index.html + template app.js) | Ornamen tanpa informasi |
| Gradasi kartu `stat-total` | Memecah keseragaman baris statistik |
| `box-shadow` pada semua kartu, kotak cari, select, nav aktif, brand-mark | Diferensiasi cukup oleh border hairline + perbedaan permukaan |
| Semua `backdrop-filter` kecuali navigasi bawah | Kaca = identitas khusus bottom nav, bukan bahasa umum |
| Kilau spekular `topbar::after` | Ornamen |
| Rotate 28° + inset highlight pada tombol ikon | Animasi hiasan |
| translateY + drop shadow berwarna pada tombol utama | Hover cukup perubahan warna |
| 2 lapis inset shadow pada FAB | Cukup satu drop shadow (elemen mengambang) |
| Trik dua warna `<em>` pada judul halaman | Gimmick tipografi template |

## 3. Perubahan color system

- Palet identitas TIDAK berubah (Warm Ivory, Deep Charcoal, Muted Teal,
  Soft Amber, Stone Gray, White) — yang berubah adalah disiplin pakai.
- Merah tetap eksklusif untuk terlambat/galat/destruktif; amber tetap
  untuk perhatian tenggat dan penanda "WAJIB".
- **Kartu statistik tidak lagi menyala teal** — strip netral; warna
  teal hanya pada angka prioritas tinggi, nav aktif, dan progres.
- Batang grafik: tiga gradient vertikal → tiga warna solid satu rumpun
  (teal-deep / teal / #b9cac7); kontras batang terang dinaikkan dari
  #c6d5d3 → #b9cac7.
- Bar kategori: gradient + inset highlight → solid `--teal`.
- `--ink-mute` digelapkan #7b8281 → **#6a6f6d** (kontras 4.61:1, WCAG AA)
  untuk seluruh teks sekunder (footer, catatan, hint).
- Sidebar & topbar: kaca semi-transparan → permukaan solid (#f7f6f2 dan
  Warm Ivory) dipisah hairline.

## 4. Perubahan typography dan spacing

- h1: `clamp(26–36px)/650` → `clamp(24–30px)/600`, line-height 1.06 → 1.18
  (lebih tenang, tidak mengejar "besar").
- Label form: 9.5px kapital tracking 0.18em → 11px normal-case 600 —
  lebih matang dan terbaca.
- Badge kesulitan/prioritas/kategori: keluar dari kapsul kapital; kini
  teks 10.5px normal dengan titik warna, radius 5px.
- Header tabel tetap kapital (konvensi tabel) tetapi tracking dirapatkan
  0.2em → 0.12em; footer 8.5px tracking 0.22em → 10.5–11px tracking wajar.
- Spacing: strip statistik tanpa gap antar-kartu (dipisah garis);
  `page-heading` mendapat ruang 30px; panel gap 14 → 16px.
- Angka statistik, hitungan nav, dan tenggat tetap `tabular-nums`.

## 5. Perubahan radius & shadow system

- Radius menurut fungsi: **12px** panel besar, **14px** modal,
  **8px** kontrol/tombol/nav item, **6px** chip kecil, **10px** dropdown;
  lingkaran hanya untuk FAB/tombol tutup/cincin progres; kapsul hanya
  untuk track toggle dan bar kategori. Navigasi bawah liquid glass tetap
  memakai radius 24px-nya sendiri sebagai elemen khusus.
- Shadow dipusatkan ke satu token `--shadow-pop` (satu lapis, lembut),
  hanya untuk elemen yang benar-benar melayang: **modal, dropdown menu
  baris, drawer ponsel, toast, navigasi bawah, FAB**. `--shadow-card`
  dihapus total. Pembedaan permukaan sehari-hari memakai hairline +
  perbedaan warna latar (ivory vs putih).

## 6. Komponen yang diperbaiki

- **Dashboard** — statistik menjadi strip editorial 4 kolom tanpa kartu
  (mobile: grid 2×2 berpisah garis); panel kategori kini `grid-column:
  1 / -1` sehingga lubang komposisi kanan hilang.
- **Sidebar** — solid, nav aktif berupa tint teal 14% tanpa bayangan;
  angka hitungan menjadi teks netral tabular (bukan kapsul).
- **Topbar** — bar solid 60px dengan hairline; tanpa blur/kilau.
- **Task list** — baris tetap tabel hairline; target sentuh tombol "···"
  mobile diperbesar 27px → 34px (kolom grid ikut disesuaikan 26 → 34px).
- **Modal** — kartu solid #fffdf9, radius 14px, satu `--shadow-pop`;
  scrim tanpa blur; label normal-case.
- **Dropdown baris** — putih solid + shadow tunggal (tetap layak dapat
  bayangan karena melayang di atas konten).
- **Toast** — pil gelap solid radius 10px, shadow tunggal, tanpa blur.
- **Grafik** — batang solid ujung tegas (3px), label sumbu X lebih
  terbaca (10.5px/500), legenda rata dengan area gambar.
- **Settings** — tiga panel putih hairline tanpa bayangan, baris
  dipisah hairline (tidak diubah strukturnya).
- **Empty state** — teks + tombol saja, tanpa grafik dekoratif.
- **Bottom nav liquid glass** — tidak disentuh sama sekali (background,
  blur, indikator, kilau, animasi WAAPI tetap utuh); tetap menjadi satu-
  satunya elemen kaca.

## 7. Yang sengaja dipertahankan

- **Liquid glass bottom nav + indikator WAAPI** — permintaan eksplisit;
  diverifikasi ulang: regang sx=1.309 pada perpindahan jauh, posisi final
  presisi 8px = offsetLeft item aktif, reduced-motion tetap instan.
- **Ikon navigasi CSS buatan tangan** (grid, list, jam, kalender, centang,
  roda gigi) — dibangun dari gradient fungsional sebagai teknik menggambar,
  bukan dekorasi.
- **Garis kisi grafik & hairline cincin progres** — fungsi pembacaan data.
- **Struktur HTML inti, semua kelas dari Zig (`task-row`, `difficulty-pill`,
  dll.)** — restyle 100% lewat CSS; `src/core.zig` tidak disentuh.
- **Bentuk lingkaran FAB & tombol tutup** — konvensi yang tepat.
- **Kontras toast gelap & scrim** — berfungsi sebagaimana mestinya.

## 8. Verifikasi (browser nyata, bukan asumsi)

- Build: 66 unit test Zig + smoke test ABI WASM lolos; SW cache v11 → v12.
- Elemen dekoratif tersisa: `querySelectorAll('.backdrop-decor, .eyebrow,
  .empty-graphic, .chart-y-labels, .workspace-label, .stat-symbol')` = 0.
- `box-shadow` panel & kartu = `none`; bar grafik `background-image: none`.
- Fungsi: statistik Zig (8/6/2/1, 25%), grafik 9 batang, 4 kategori,
  tambah tugas + toast, toggle selesai, hapus + dialog konfirmasi,
  pencarian, ekspor, izin notifikasi (reset benar saat izin ditolak),
  drawer mobile buka-tutup — semuanya berjalan.
- Navigasi bawah: tersembunyi di ≥768px, tampil di ≤430px; indikator
  akurat setelah resize; `prefers-reduced-motion` → lompatan instan
  (283px = 283px, sx=1.00).
- Luapan horizontal = 0 pada 320/390/430/768/1050/1280/1440px.
- Tanpa error konsol sepanjang sesi pengujian.
- Tangkapan layar sebelum/sesudah: `download/ordexa-before-after/`.

## 9. Tidak dikerjakan & alasannya

- **Menyeimbangkan tinggi kolom halaman Pengaturan** (panel kanan lebih
  pendek) — perbedaan konten riil antar panel; memaksa setara justru
  menambah padding kosong, bertentangan dengan prinsip "tanpa padding
  berlebihan".
- **Label nilai pada batang grafik** — nilai sudah tersedia via tooltip
  hover/title; menambah angka permanen pada grafik mini menambah derau.
  Jika kelak diminta, cukup aktifkan `chart-bar:hover::after` permanen.
- **Sidebar "tidak setinggi viewport" pada tangkapan layar halaman penuh** —
  artefak render elemen `position: fixed` pada screenshot fullpage, bukan
  bug nyata (di viewport nyata sidebar selalu full height).
