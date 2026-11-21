// Inti logika bisnis Ordexa.
// Dikompilasi menjadi WebAssembly lalu dipanggil oleh antarmuka peramban.
// Seluruh logika perencanaan hidup di sini: skor prioritas, validasi,
// penyaringan tampilan, pencocokan pencarian, urutan tampilan, statistik,
// klasifikasi tenggat, agregasi grafik beban kerja, sebaran kategori,
// penanda gaya baris, perakitan HTML baris tugas, kalender sipil,
// format tanggal Indonesia, serta seluruh teks antarmuka.
// Lapisan JavaScript hanya merender, menyimpan, dan menyiapkan masukan.
//
// ---------------------------------------------------------------------------
// KONTRAK ABI WEBASSEMBLY (ringkas)
// ---------------------------------------------------------------------------
// Konvensi umum yang dipatuhi seluruh ekspor di bawah:
//
//   1. Bilangan waktu selalu berupa detik Unix (i64), bukan milidetik.
//      Zona waktu diteruskan sebagai offset detik (timur positif), yaitu
//      `-new Date().getTimezoneOffset() * 60` di sisi JavaScript.
//
//   2. String tidak pernah dialokasikan oleh inti. Pemanggil menulis byte
//      UTF-8 mentah ke arena goresan (ordexa_scratch_alloc) lalu mengoper
//      alamat + panjangnya. Hasil teks dibaca dari penyangga statis:
//        - tabel string  : ordexa_string_ptr / ordexa_string_len (id -> teks)
//        - pesan berangka: ordexa_format_message -> ordexa_format_ptr
//        - HTML baris    : ordexa_render_task_row -> ordexa_row_ptr
//      Panjang kembalian nol selalu berarti kegagalan atau kosong.
//
//   3. Larik dipakai dalam tata letak i64/u32 rapat tanpa struct;
//      dokumentasi tiap ekspor menuliskan urutan bidangnya.
//
//   4. Semua ekspor murni (tanpa keadaan global yang menetap kecuali arena
//      goresan dan penyangga keluaran), aman dipanggil berulang tanpa
//      pembersihan selama arena di-reset di awal putaran render.
//
//   5. Kesulitan tugas: 1 ringan, 2 sedang, 3 berat.
//      Status tugas   : 0 aktif, 1 selesai (satu bit).
//      Pita prioritas : 0 rendah, 1 sedang, 2 tinggi, 3 kritis.
//      Urgensi        : 0 santai, 1 segera, 2 mendesak, 3 terlambat.
//      Kategori       : 0 Belajar, 1 Kerja, 2 Pribadi, 3 Proyek, 4 Lainnya.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const SKOR_MAKS: u32 = 100;
const DETIK_PER_HARI: i64 = 86400;

// ---------------------------------------------------------------------------
// CATATAN DESAIN: MODEL SKOR PRIORITAS
// ---------------------------------------------------------------------------
// Skor 0..100 adalah penjumlahan dua kontribusi:
//
//   skor = bobot_kesulitan + urgensi    (dipotong di SKOR_MAKS)
//
//   Bobot kesulitan (kontribusi dasar "seberapa berat pekerjaan ini"):
//     Ringan  1 -> 18
//     Sedang  2 -> 42
//     Berat   3 -> 66
//     Nilai lain dipetakan ke Ringan agar data rusak tidak melahirkan skor liar.
//
//   Urgensi (kontribusi "seberapa cepat harus dikerjakan", dari sisa jam):
//     terlambat (jam < 0)      -> 34  (maksimum; lewat tenggat paling menekan)
//     jam <= 6  (< 6 jam)      -> 34
//     jam <= 24 (hari ini)     -> 29
//     jam <= 72 (3 hari)       -> 22
//     jam <= 168 (minggu ini)  -> 13
//     jam <= 336 (2 minggu)    -> 7
//     lebih lama              -> 2
//
//   Konsekuensi yang dijaga oleh tes "skor tidak pernah turun...":
//     - skor monoton naik saat waktu makin sempit, pada tiap kesulitan;
//     - skor naik saat kesulitan naik, pada sisa waktu sama;
//     - kombinasi terburuk (berat + terlambat) = 66 + 34 = 100 pas di batas.
//
//   Pita prioritas memetakan skor ke empat kelas tampilan:
//     0..41 rendah, 42..64 sedang, 65..84 tinggi, 85..100 kritis.
//   Keranjang urgensi (untuk grafik dan kelas tenggat) memakai batas jam:
//     0 santai, 1 segera (<=72 jam), 2 mendesak (<=24 jam), 3 terlambat (<0).

// ---------------------------------------------------------------------------
// Ekspor tugas tunggal (dipakai untuk validasi langsung dan diagnosis)
// ---------------------------------------------------------------------------

/// Ubah tenggat Unix menjadi sisa jam bulat. Tenggat yang lewat bernilai negatif.
export fn ordexa_hours_left(tenggat_detik: i64, kini_detik: i64) i64 {
    return @divFloor(tenggat_detik - kini_detik, 3600);
}

/// kesulitan: 1 = ringan, 2 = sedang, 3 = berat
/// sisa_jam: jam bertanda hingga tenggat (negatif berarti terlambat)
/// Mengembalikan skor 0..100. Semakin besar semakin mendesak / berat.
export fn ordexa_score(kesulitan: u32, sisa_jam: i64) u32 {
    const bobot_kesulitan: u32 = switch (kesulitan) {
        1 => 18,
        2 => 42,
        3 => 66,
        else => 18,
    };

    const urgensi: u32 = if (sisa_jam < 0)
        34
    else if (sisa_jam <= 6)
        34
    else if (sisa_jam <= 24)
        29
    else if (sisa_jam <= 72)
        22
    else if (sisa_jam <= 168)
        13
    else if (sisa_jam <= 336)
        7
    else
        2;

    return @min(SKOR_MAKS, bobot_kesulitan + urgensi);
}

/// Mengembalikan pita prioritas: 0 = rendah, 1 = sedang, 2 = tinggi, 3 = kritis.
export fn ordexa_priority_band(skor: u32) u32 {
    if (skor >= 85) return 3;
    if (skor >= 65) return 2;
    if (skor >= 42) return 1;
    return 0;
}

/// Mengembalikan keranjang urgensi: 0 = santai, 1 = segera, 2 = mendesak, 3 = terlambat.
export fn ordexa_urgency(sisa_jam: i64) u32 {
    if (sisa_jam < 0) return 3;
    if (sisa_jam <= 24) return 2;
    if (sisa_jam <= 72) return 1;
    return 0;
}

/// Mengembalikan 1 ketika judul dan tenggat valid.
/// panjang_judul dihitung dalam byte UTF-8 oleh pemanggil.
export fn ordexa_validate(panjang_judul: u32, tenggat_detik: i64, kini_detik: i64) u32 {
    if (panjang_judul == 0 or panjang_judul > 480) return 0;
    if (tenggat_detik <= 0) return 0;
    // Tenggat yang sudah lewat tetap diizinkan untuk tugas impor atau yang telat.
    _ = kini_detik;
    return 1;
}

/// Versi validasi yang kaya: mengembalikan 0 saat valid, atau ID string
/// pesan kesalahan (lihat tabel ui_strings) saat masukan ditolak.
export fn ordexa_validate_ex(panjang_judul: u32, tenggat_detik: i64) u32 {
    if (panjang_judul == 0) return S_FORM_JUDUL_KOSONG;
    if (panjang_judul > 480) return S_FORM_JUDUL_PANJANG;
    if (tenggat_detik <= 0) return S_FORM_TENGGAT;
    return 0;
}

/// Hitung persentase penyelesaian tanpa bilangan pecahan.
export fn ordexa_completion_percent(total: u32, selesai: u32) u32 {
    if (total == 0) return 0;
    const selesai_aman = @min(total, selesai);
    return @intCast((@as(u64, selesai_aman) * 100) / total);
}

// ---------------------------------------------------------------------------
// Bantuan kalender
// ---------------------------------------------------------------------------

/// Indeks hari kalender setempat, memperhitungkan offset UTC pemanggil.
fn hariLokal(detik_unix: i64, offset_zona_detik: i64) i64 {
    return @divFloor(detik_unix + offset_zona_detik, DETIK_PER_HARI);
}

/// Klasifikasikan tenggat relatif terhadap hari kalender setempat: 0 hari ini, 1 besok, 2 nanti.
export fn ordexa_deadline_kind(tenggat: i64, kini: i64, offset_zona_detik: i64) u32 {
    const selisih = hariLokal(tenggat, offset_zona_detik) - hariLokal(kini, offset_zona_detik);
    if (selisih == 0) return 0;
    if (selisih == 1) return 1;
    return 2;
}

// ---------------------------------------------------------------------------
// Tabel string antarmuka berbahasa Indonesia
// ---------------------------------------------------------------------------
// Seluruh teks statis UI hidup di dalam modul Zig. Lapisan JS cukup membaca
// byte UTF-8 dari memori linear menurut ID string, sehingga tidak ada
// kamus label kembar di sisi JavaScript.

const S_RINGAN: u32 = 0; // label kesulitan 1
const S_SEDANG: u32 = 1; // label kesulitan 2 dan pita prioritas 1
const S_BERAT: u32 = 2; // label kesulitan 3
const S_RENDAH: u32 = 3; // pita prioritas 0
const S_TINGGI: u32 = 4; // pita prioritas 2
const S_KRITIS: u32 = 5; // pita prioritas 3
const S_HARI_INI: u32 = 6; // jenis tenggat 0
const S_BESOK: u32 = 7; // jenis tenggat 1
const S_TANPA_TENGGAT: u32 = 8;
const S_TERLAMBAT: u32 = 9; // prefiks baris tenggat lewat
const S_TOAST_TAMBAH: u32 = 10;
const S_TOAST_UBAH: u32 = 11;
const S_TOAST_SELESAI: u32 = 12;
const S_TOAST_AKTIF: u32 = 13;
const S_TOAST_HAPUS: u32 = 14;
const S_TOAST_EKSPOR: u32 = 15;
const S_TOAST_STORAGE: u32 = 16;
const S_TOAST_WASM_GAGAL: u32 = 17;
const S_ENGINE_AKTIF: u32 = 18;
const S_ENGINE_MATI: u32 = 19;
const S_ENGINE_MEMUAT: u32 = 20;
const S_FORM_JUDUL_KOSONG: u32 = 21;
const S_FORM_TENGGAT: u32 = 22;
const S_FORM_DETAIL: u32 = 23;
const S_FORM_JUDUL_PANJANG: u32 = 24;
const S_FORM_ENGINE: u32 = 25;
const S_AKSI_TANDAI_AKTIF: u32 = 26;
const S_AKSI_TANDAI_SELESAI: u32 = 27;
const S_AKSI_EDIT: u32 = 28;
const S_AKSI_HAPUS: u32 = 29;
const S_ARIA_AKSI: u32 = 30;
const S_MODAL_BUAT: u32 = 31;
const S_MODAL_SIMPAN_UBAH: u32 = 32;
const S_MODAL_SIMPAN: u32 = 33;
const S_IMPOR_GAGAL: u32 = 34;
const S_KOSONG_CHART: u32 = 35;
const S_HAPUS_A: u32 = 36; // 'Hapus "' (awal konfirmasi hapus)
const S_HAPUS_B: u32 = 37; // '"? Tindakan ini tidak bisa dibatalkan.'
// Judul dan subjudul tampilan daftar (indeks 38..45).
const S_VIEW_SEMUA_JUDUL: u32 = 38;
const S_VIEW_SEMUA_SUB: u32 = 39;
const S_VIEW_HARI_INI_JUDUL: u32 = 40;
const S_VIEW_HARI_INI_SUB: u32 = 41;
const S_VIEW_DATANG_JUDUL: u32 = 42;
const S_VIEW_DATANG_SUB: u32 = 43;
const S_VIEW_SELESAI_JUDUL: u32 = 44;
const S_VIEW_SELESAI_SUB: u32 = 45;
// Teks keadaan kosong dan tombol buat tugas (indeks 46..50).
const S_KOSONG_LIST_JUDUL: u32 = 46;
const S_KOSONG_LIST_SUB: u32 = 47;
const S_BUAT_TUGAS: u32 = 48;
const S_KOSONG_FOKUS_JUDUL: u32 = 49;
const S_KOSONG_FOKUS_SUB: u32 = 50;
// Nama kategori tugas (indeks 51..55, urutan = ID kategori 0..4).
const S_KAT_BELAJAR: u32 = 51;
const S_KAT_KERJA: u32 = 52;
const S_KAT_PRIBADI: u32 = 53;
const S_KAT_PROYEK: u32 = 54;
const S_KAT_LAINNYA: u32 = 55;
// Versi inti (ditampilkan di panel pengaturan).
const S_VERSI_CORE: u32 = 56;
const S_PENGATURAN_VERSI: u32 = 57;
// Judul notifikasi (pengingat harian dan peringatan tugas mepet).
const S_NOTIF_HARIAN_JUDUL: u32 = 58;
const S_NOTIF_MEPET_JUDUL: u32 = 59;

const ui_strings = [_][]const u8{
    "Ringan",
    "Sedang",
    "Berat",
    "Rendah",
    "Tinggi",
    "Kritis",
    "Hari ini",
    "Besok",
    "Tanpa tenggat",
    "Terlambat · ",
    "Tugas berhasil ditambahkan.",
    "Perubahan tugas berhasil disimpan.",
    "Tugas berhasil ditandai selesai.",
    "Tugas berhasil dikembalikan ke aktif.",
    "Tugas berhasil dihapus.",
    "Cadangan berhasil diekspor.",
    "Penyimpanan penuh atau tidak tersedia. Ekspor cadangan Anda.",
    "Inti Zig gagal dimuat. Muat ulang halaman lalu coba lagi.",
    "Inti Zig aktif",
    "Inti Zig tidak tersedia",
    "Memuat inti Zig",
    "Judul tugas belum diisi.",
    "Pilih tenggat waktu yang valid.",
    "Periksa kembali detail tugas.",
    "Judul tugas terlalu panjang.",
    "Inti Zig belum siap. Muat ulang halaman lalu coba lagi.",
    "Tandai aktif",
    "Tandai selesai",
    "Edit tugas",
    "Hapus tugas",
    "Aksi tugas",
    "Tambah tugas",
    "Simpan perubahan",
    "Simpan tugas",
    "Gagal mengimpor berkas ini. Periksa cadangan JSON.",
    "Belum ada tugas aktif untuk ditampilkan.",
    "Hapus \"",
    "\"? Tindakan ini tidak dapat dibatalkan.",
    // Judul dan subjudul tampilan daftar.
    "Semua tugas",
    "Cari, saring, dan urutkan seluruh tugas Anda.",
    "Hari ini",
    "Tugas yang jatuh tempo hari ini.",
    "Akan datang",
    "Tugas aktif dengan tenggat di masa depan.",
    "Selesai",
    "Tugas yang sudah Anda selesaikan.",
    // Teks keadaan kosong.
    "Tidak ada tugas yang cocok.",
    "Ubah kata kunci pencarian atau tambahkan tugas baru.",
    "Tambah tugas",
    "Belum ada tugas.",
    "Tambahkan tugas untuk mulai memantau prioritas.",
    // Nama kategori (urutan = ID kategori).
    "Belajar",
    "Kerja",
    "Pribadi",
    "Proyek",
    "Lainnya",
    // Versi inti.
    "Inti Ordexa v2.1 (Zig + WebAssembly)",
    "Versi inti",
    // Judul notifikasi.
    "Sudah buka Ordexa hari ini?",
    "Tenggat mendekat",
};

/// Jumlah string UI yang tersedia di dalam modul.
export fn ordexa_string_count() u32 {
    return ui_strings.len;
}

/// Alamat byte pertama string menurut ID, atau 0 bila ID tidak dikenal.
export fn ordexa_string_ptr(id: u32) usize {
    if (id >= ui_strings.len) return 0;
    return @intFromPtr(ui_strings[id].ptr);
}

/// Panjang string dalam byte UTF-8 menurut ID, atau 0 bila ID tidak dikenal.
export fn ordexa_string_len(id: u32) u32 {
    if (id >= ui_strings.len) return 0;
    return @intCast(ui_strings[id].len);
}

/// ID label kesulitan: 1 -> Ringan, 2 -> Sedang, 3 -> Berat.
export fn ordexa_difficulty_label_id(kesulitan: u32) u32 {
    return switch (kesulitan) {
        1 => S_RINGAN,
        2 => S_SEDANG,
        3 => S_BERAT,
        else => S_RINGAN,
    };
}

/// ID label pita prioritas: 0 rendah, 1 sedang, 2 tinggi, 3 kritis.
export fn ordexa_priority_label_id(pita: u32) u32 {
    return switch (pita) {
        0 => S_RENDAH,
        1 => S_SEDANG,
        2 => S_TINGGI,
        3 => S_KRITIS,
        else => S_RENDAH,
    };
}

/// ID label jenis tenggat: 0 hari ini, 1 besok, 2 (tanggal penuh di sisi JS).
export fn ordexa_kind_label_id(jenis: u32) u32 {
    return switch (jenis) {
        0 => S_HARI_INI,
        1 => S_BESOK,
        else => S_TANPA_TENGGAT,
    };
}

// ---------------------------------------------------------------------------
// Pemformat pesan dengan angka
// ---------------------------------------------------------------------------
// Pesan yang memuat jumlah tugas memakai templat dengan penanda {0} dan {1}.
// Hasil ditulis ke penyangga internal dan dibaca JS lewat ordexa_format_ptr().

const M_IMPOR_OK: u32 = 100;
const M_IMPOR_KONFIRMASI: u32 = 101;
// Isi pengingat harian; varian dipilih JS menurut jumlah tugas aktif/mepet.
const M_NOTIF_HARIAN_KOSONG: u32 = 102;
const M_NOTIF_HARIAN_SANTAI: u32 = 103;
const M_NOTIF_HARIAN_MEPET: u32 = 104;

const pesan_templat = [_][]const u8{
    "{0} tugas berhasil diimpor.",
    "Cadangan berisi {0} tugas dan akan menggantikan {1} tugas saat ini. Lanjutkan?",
    "Belum ada tugas terjadwal. Tambahkan satu untuk hari ini?",
    "Ada {0} tugas aktif di Ordexa. Yang mana yang dikerjakan lebih dulu?",
    "Ada {0} tugas aktif, {1} di antaranya mendekati tenggat.",
};

const UKURAN_PENYANGGA_FORMAT: usize = 256;
var penyangga_format: [UKURAN_PENYANGGA_FORMAT]u8 = undefined;

/// Alamat penyangga hasil pemformatan (dipakai JS setelah memanggil formatter).
export fn ordexa_format_ptr() usize {
    return @intFromPtr(&penyangga_format);
}

/// Format pesan `id_pesan` dengan hingga dua angka lalu kembalikan panjang
/// hasil dalam byte. Mengembalikan 0 bila ID tidak dikenal atau hasil kepanjangan.
export fn ordexa_format_message(id_pesan: u32, a: i64, b: i64) u32 {
    if (id_pesan < 100) return 0;
    const indeks = id_pesan - 100;
    if (indeks >= pesan_templat.len) return 0;
    const templat = pesan_templat[indeks];

    var n: usize = 0;
    var i: usize = 0;
    while (i < templat.len) {
        // Penanda posisi berbentuk {0} atau {1}.
        if (templat[i] == '{' and i + 2 < templat.len and templat[i + 2] == '}' and
            (templat[i + 1] == '0' or templat[i + 1] == '1'))
        {
            const nilai: i64 = if (templat[i + 1] == '0') a else b;
            const potongan = std.fmt.bufPrint(penyangga_format[n..], "{d}", .{nilai}) catch return 0;
            n += potongan.len;
            i += 3;
        } else {
            if (n >= UKURAN_PENYANGGA_FORMAT) return 0;
            penyangga_format[n] = templat[i];
            n += 1;
            i += 1;
        }
    }
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Penulis penyangga: utilitas menulis byte, angka, dan teks terlindung HTML
// ---------------------------------------------------------------------------
// Seluruh perakitan teks keluaran (tanggal, sisa waktu, HTML baris tugas)
// memakai utilitas kecil ini agar pembatasan penyangga diperiksa di satu tempat.

const Penulis = struct {
    penyangga: []u8,
    n: usize = 0,

    /// Tulis satu byte; gagal bila penyangga penuh.
    fn byte(p: *Penulis, b: u8) bool {
        if (p.n >= p.penyangga.len) return false;
        p.penyangga[p.n] = b;
        p.n += 1;
        return true;
    }

    /// Tulis potongan teks mentah (tanpa pengamanan HTML).
    fn potongan(p: *Penulis, teks: []const u8) bool {
        for (teks) |b| {
            if (!p.byte(b)) return false;
        }
        return true;
    }

    /// Tulis bilangan bulat dalam basis desimal.
    fn angka(p: *Penulis, nilai: anytype) bool {
        var sementara: [24]u8 = undefined;
        const teks = std.fmt.bufPrint(&sementara, "{d}", .{nilai}) catch return false;
        return p.potongan(teks);
    }

    /// Tulis jam gaya Indonesia, mis. "14.05" (pemisah titik, bukan titik dua).
    fn jam(p: *Penulis, detik_harian: u32) bool {
        const hh = detik_harian / 3600;
        const mm = (detik_harian % 3600) / 60;
        var sementara: [12]u8 = undefined;
        const teks = std.fmt.bufPrint(&sementara, "{d:0>2}.{d:0>2}", .{ hh, mm }) catch return false;
        return p.potongan(teks);
    }

    /// Tulis teks dengan pengamanan HTML: lima karakter berbahaya digantikan
    /// entitasnya sehingga judul/catatan tugas tidak bisa menyuntik markup.
    fn terlindung(p: *Penulis, teks: []const u8) bool {
        for (teks) |b| {
            const pengganti: ?[]const u8 = switch (b) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => null,
            };
            if (pengganti) |entitas| {
                if (!p.potongan(entitas)) return false;
            } else if (!p.byte(b)) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Kalender sipil dan format tanggal berbahasa Indonesia
// ---------------------------------------------------------------------------
// Semua label tanggal dan jam pada antarmuka diformat di sini sehingga
// lapisan JS tidak lagi memakai Intl/perpustakaan tanggal peramban.
// Konversi hari-since-epoch ke tanggal kalender memakai algoritma
// civil_from_days karya Howard Hinnant (bebas dari tabel dan loop tahun).

/// Nama hari pendek, indeks 0 = Minggu (mengikuti getDay() JavaScript).
const NAMA_HARI = [_][]const u8{ "Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab" };

/// Nama bulan pendek berbahasa Indonesia, indeks 0 = Januari.
const NAMA_BULAN = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des" };

const TanggalSipil = struct { tahun: i64, bulan: u32, hari: u32 };

/// Ubah jumlah hari sejak epoch Unix (1970-01-01) menjadi tanggal kalender
/// Gregorian proleptik. Berlaku untuk nilai negatif maupun jauh di masa depan.
fn tanggalSipil(z: i64) TanggalSipil {
    const zz = z + 719_468;
    const era = @divFloor(zz, 146_097);
    const doe = zz - era * 146_097; // hari dalam era, [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const tahun = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const hari = doy - @divFloor(153 * mp + 2, 5) + 1;
    const bulan = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .tahun = if (bulan <= 2) tahun + 1 else tahun,
        .bulan = @intCast(bulan),
        .hari = @intCast(hari),
    };
}

/// Indeks hari dalam minggu (0 = Minggu) dari jumlah hari sejak epoch.
/// Hari epoch ke-0 (1970-01-01) adalah Kamis (indeks 4).
fn indeksHari(z: i64) u32 {
    return @intCast(@mod(z + 4, 7));
}

/// Inverse tanggalSipil: ubah tanggal kalender menjadi jumlah hari sejak
/// epoch (algoritma days_from_civil karya Howard Hinnant). Dipakai tes
/// untuk memverifikasi bolak-balik konversi kalender.
fn hariDariTanggal(tahun: i64, bulan: u32, hari: u32) i64 {
    const y = if (bulan <= 2) tahun - 1 else tahun;
    const m: i64 = @intCast(if (bulan > 2) bulan - 3 else bulan + 9);
    const d: i64 = @intCast(hari);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divFloor(153 * m + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// Pecah detik Unix menjadi hari kalender setempat dan detik sejak tengah malam.
fn pecahWaktuLokal(detik_unix: i64, offset_zona_detik: i64) struct { hari: i64, detik_harian: u32 } {
    const lokal = detik_unix + offset_zona_detik;
    const hari = @divFloor(lokal, DETIK_PER_HARI);
    return .{ .hari = hari, .detik_harian = @intCast(lokal - hari * DETIK_PER_HARI) };
}

/// Tulis label tenggat: "Hari ini, 14.00", "Besok, 09.00", "Kemarin, 23.00",
/// "4 Jan, 10.00" untuk hari lain di tahun yang sama, atau "5 Jan 2027, 09.00"
/// bila tahunnya berbeda dengan tahun sekarang.
fn tulisTenggat(p: *Penulis, tenggat: i64, kini: i64, offset_zona_detik: i64) bool {
    const waktu = pecahWaktuLokal(tenggat, offset_zona_detik);
    const selisih = waktu.hari - hariLokal(kini, offset_zona_detik);
    if (selisih == 0) {
        if (!p.potongan("Hari ini, ")) return false;
    } else if (selisih == 1) {
        if (!p.potongan("Besok, ")) return false;
    } else if (selisih == -1) {
        if (!p.potongan("Kemarin, ")) return false;
    } else {
        const t = tanggalSipil(waktu.hari);
        if (t.bulan < 1 or t.bulan > 12) return false;
        if (!p.angka(t.hari)) return false;
        if (!p.potongan(" ")) return false;
        if (!p.potongan(NAMA_BULAN[t.bulan - 1])) return false;
        // Tahun ditulis hanya bila berbeda dengan tahun waktu sekarang.
        const tahun_kini = tanggalSipil(hariLokal(kini, offset_zona_detik)).tahun;
        if (t.tahun != tahun_kini) {
            if (!p.potongan(" ")) return false;
            if (!p.angka(t.tahun)) return false;
        }
        if (!p.potongan(", ")) return false;
    }
    return p.jam(waktu.detik_harian);
}

/// Tulis sisa waktu relatif: "2 jam lagi", "3 hari lagi", "terlambat 5 jam",
/// atau "lebih dari setahun" untuk rentang sangat panjang.
fn tulisRelatifJam(p: *Penulis, sisa_jam: i64) bool {
    const lampau = sisa_jam < 0;
    const besar: u64 = @intCast(if (lampau) -sisa_jam else sisa_jam);
    if (lampau and !p.potongan("terlambat ")) return false;
    if (besar >= 24 * 365) {
        if (!p.potongan("lebih dari setahun")) return false;
    } else if (besar >= 48) {
        if (!p.angka(@divFloor(besar, 24))) return false;
        if (!p.potongan(" hari")) return false;
    } else if (besar == 0) {
        if (!p.potongan("kurang dari satu jam")) return false;
    } else {
        if (!p.angka(besar)) return false;
        if (!p.potongan(" jam")) return false;
    }
    if (!lampau and !p.potongan(" lagi")) return false;
    return true;
}

/// Format label tenggat lengkap ke penyangga format; kembalikan panjang byte.
/// Baca hasilnya lewat ordexa_format_ptr().
export fn ordexa_format_deadline(tenggat: i64, kini: i64, offset_zona_detik: i64) u32 {
    var p = Penulis{ .penyangga = &penyangga_format };
    if (!tulisTenggat(&p, tenggat, kini, offset_zona_detik)) return 0;
    return @intCast(p.n);
}

/// Format label tanggal bilah atas, mis. "Jum, 21 Nov".
export fn ordexa_format_date_label(kini: i64, offset_zona_detik: i64) u32 {
    const waktu = pecahWaktuLokal(kini, offset_zona_detik);
    const t = tanggalSipil(waktu.hari);
    var p = Penulis{ .penyangga = &penyangga_format };
    if (t.bulan < 1 or t.bulan > 12) return 0;
    if (!p.potongan(NAMA_HARI[indeksHari(waktu.hari)])) return 0;
    if (!p.potongan(", ")) return 0;
    if (!p.angka(t.hari)) return 0;
    if (!p.potongan(" ")) return 0;
    if (!p.potongan(NAMA_BULAN[t.bulan - 1])) return 0;
    return @intCast(p.n);
}

/// Format sisa waktu relatif (tooltip sel tanggal), mis. "3 hari lagi".
export fn ordexa_format_relative(sisa_jam: i64) u32 {
    var p = Penulis{ .penyangga = &penyangga_format };
    if (!tulisRelatifJam(&p, sisa_jam)) return 0;
    return @intCast(p.n);
}

/// Format nilai bawaan bidang datetime-local, mis. "1970-01-02T07:00",
/// yaitu waktu setempat `tambah_jam` jam dari sekarang dengan menit dibulatkan nol.
export fn ordexa_format_input_deadline(kini: i64, offset_zona_detik: i64, tambah_jam: i32) u32 {
    const target = kini + @as(i64, tambah_jam) * 3600;
    const waktu = pecahWaktuLokal(target, offset_zona_detik);
    const t = tanggalSipil(waktu.hari);
    var p = Penulis{ .penyangga = &penyangga_format };
    if (t.tahun < 0 or t.tahun > 9999) return 0;
    var sementara: [32]u8 = undefined;
    const teks = std.fmt.bufPrint(&sementara, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:00", .{
        @as(u32, @intCast(t.tahun)), t.bulan, t.hari, waktu.detik_harian / 3600,
    }) catch return 0;
    if (!p.potongan(teks)) return 0;
    return @intCast(p.n);
}

/// ID label kategori menurut ID kategori 0..4.
export fn ordexa_category_label_id(kategori: u32) u32 {
    return switch (kategori) {
        0 => S_KAT_BELAJAR,
        1 => S_KAT_KERJA,
        2 => S_KAT_PRIBADI,
        3 => S_KAT_PROYEK,
        else => S_KAT_LAINNYA,
    };
}

/// Versi inti sebagai string statis; panjangnya dikembalikan lewat keluaran.
export fn ordexa_version_string() u32 {
    return @intCast(ui_strings[S_VERSI_CORE].len);
}

// ---------------------------------------------------------------------------
// Memori goresan: lapisan JS meminjam penyangga ini untuk menyiapkan
// string dan larik sebelum memanggil ekspor mesin
// ---------------------------------------------------------------------------

const UKURAN_GORESAN: usize = 512 * 1024;
var goresan: [UKURAN_GORESAN]u8 align(16) = undefined;
var offset_goresan: usize = 0;

/// Atur ulang arena goresan. Panggil di awal tiap putaran mesin.
export fn ordexa_scratch_reset() void {
    offset_goresan = 0;
}

/// Cadangkan `panjang` byte lalu kembalikan alamatnya, atau 0 bila arena penuh.
export fn ordexa_scratch_alloc(panjang: u32) usize {
    const sejajar = (offset_goresan + 15) & ~@as(usize, 15);
    const akhir = sejajar + panjang;
    if (akhir > UKURAN_GORESAN) return 0;
    offset_goresan = akhir;
    return @intFromPtr(&goresan) + sejajar;
}

// ---------------------------------------------------------------------------
// Pencarian tanpa pedulikan besar-kecil (huruf ASCII dilipat; byte lain dibanding persis)
// ---------------------------------------------------------------------------

fn byteKecil(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn memuatKecil(jerami: []const u8, jarum: []const u8) bool {
    if (jarum.len == 0) return true;
    if (jarum.len > jerami.len) return false;
    var awal: usize = 0;
    while (awal + jarum.len <= jerami.len) : (awal += 1) {
        var i: usize = 0;
        while (i < jarum.len) : (i += 1) {
            if (byteKecil(jerami[awal + i]) != byteKecil(jarum[i])) break;
        }
        if (i == jarum.len) return true;
    }
    return false;
}

/// Mengembalikan 1 ketika jerami memuat jarum, tanpa pedulikan besar-kecil ASCII.
export fn ordexa_contains_lower(alamat_jerami: usize, panjang_jerami: u32, alamat_jarum: usize, panjang_jarum: u32) u32 {
    const jerami: [*]const u8 = @ptrFromInt(alamat_jerami);
    const jarum: [*]const u8 = @ptrFromInt(alamat_jarum);
    return if (memuatKecil(jerami[0..panjang_jerami], jarum[0..panjang_jarum])) 1 else 0;
}

// ---------------------------------------------------------------------------
// Analisis massal
// ---------------------------------------------------------------------------

/// Turunkan seluruh nilai perencanaan milik satu tugas dalam satu jalan.
fn analisaTugas(tenggat: i64, status: i64, kesulitan: i64, kini: i64) [5]i64 {
    const id_kesulitan: u32 = switch (kesulitan) {
        1, 2, 3 => @intCast(kesulitan),
        else => 1,
    };
    const jam = ordexa_hours_left(tenggat, kini);
    const skor = ordexa_score(id_kesulitan, jam);
    const pita = ordexa_priority_band(skor);
    const urgensi = ordexa_urgency(jam);
    const terlambat: i64 = if (status != 1 and urgensi == 3) 1 else 0;
    return .{ jam, @intCast(skor), @intCast(pita), @intCast(urgensi), terlambat };
}

/// masuk: jumlah * 3 i64  (tenggat_detik, status, kesulitan)
/// keluar: jumlah * 5 i64  (sisa_jam, skor, pita, urgensi, terlambat)
export fn ordexa_analyze(jumlah: u32, ptr_masuk: usize, ptr_keluar: usize, kini: i64) void {
    if (jumlah == 0) return;
    const larik_masuk: [*]const i64 = @ptrFromInt(ptr_masuk);
    const larik_keluar: [*]i64 = @ptrFromInt(ptr_keluar);
    var i: usize = 0;
    while (i < jumlah) : (i += 1) {
        const hasil = analisaTugas(larik_masuk[i * 3], larik_masuk[i * 3 + 1], larik_masuk[i * 3 + 2], kini);
        var j: usize = 0;
        while (j < 5) : (j += 1) larik_keluar[i * 5 + j] = hasil[j];
    }
}

// ---------------------------------------------------------------------------
// Statistik
// ---------------------------------------------------------------------------

/// kunci: jumlah * 2 i64 (tenggat_detik, status)
/// keluar: 5 i64 (total, selesai, aktif, terlambat, persen_penyelesaian)
export fn ordexa_stats(jumlah: u32, ptr_kunci: usize, kini: i64, ptr_keluar: usize) void {
    const keluar: [*]i64 = @ptrFromInt(ptr_keluar);
    if (jumlah == 0) {
        keluar[0] = 0;
        keluar[1] = 0;
        keluar[2] = 0;
        keluar[3] = 0;
        keluar[4] = 0;
        return;
    }
    const kunci: [*]const i64 = @ptrFromInt(ptr_kunci);
    var selesai: u32 = 0;
    var terlambat: u32 = 0;
    var i: usize = 0;
    while (i < jumlah) : (i += 1) {
        if (kunci[i * 2 + 1] == 1) {
            selesai += 1;
        } else if (kunci[i * 2] < kini) {
            terlambat += 1;
        }
    }
    keluar[0] = @intCast(jumlah);
    keluar[1] = @intCast(selesai);
    keluar[2] = @intCast(jumlah - selesai);
    keluar[3] = @intCast(terlambat);
    keluar[4] = @intCast(ordexa_completion_percent(jumlah, selesai));
}

// ---------------------------------------------------------------------------
// Grafik beban kerja
// ---------------------------------------------------------------------------

/// Kunci per tugas: 3 i64 (tenggat_detik, status, kesulitan).
/// Keluaran: 10 i64 — hitungan[grup * 3 + tingkat] untuk tugas aktif,
///   grup: 0 mendesak (urgensi >= 2), 1 segera (urgensi 1), 2 nanti (urgensi 0);
///   tingkat: 0 berat, 1 sedang, 2 ringan;
///   indeks 9 menyimpan nilai maksimum di antara 9 batang (untuk skala tinggi).
export fn ordexa_chart(jumlah: u32, ptr_kunci: usize, kini: i64, ptr_keluar: usize) void {
    const keluar: [*]i64 = @ptrFromInt(ptr_keluar);
    var i: usize = 0;
    while (i < 10) : (i += 1) keluar[i] = 0;
    if (jumlah == 0) return;

    const kunci: [*]const i64 = @ptrFromInt(ptr_kunci);
    i = 0;
    while (i < jumlah) : (i += 1) {
        const tenggat = kunci[i * 3];
        const status = kunci[i * 3 + 1];
        const kesulitan = kunci[i * 3 + 2];
        if (status == 1) continue; // tugas selesai tidak masuk grafik

        const urgensi = ordexa_urgency(ordexa_hours_left(tenggat, kini));
        const grup: usize = if (urgensi >= 2) 0 else if (urgensi == 1) 1 else 2;
        const tingkat: usize = switch (kesulitan) {
            1 => 2, // ringan
            2 => 1, // sedang
            3 => 0, // berat
            else => 1,
        };
        keluar[grup * 3 + tingkat] += 1;
    }

    var maks: i64 = 0;
    i = 0;
    while (i < 9) : (i += 1) maks = @max(maks, keluar[i]);
    keluar[9] = maks;
}

// ---------------------------------------------------------------------------
// Penanda gaya baris tugas
// ---------------------------------------------------------------------------

/// Padatkan keputusan tampilan satu baris tugas menjadi satu bilangan:
///   bit 0    : judul dicoret (status selesai)
///   bit 1..2 : kelas prioritas CSS (0 rendah, 1 sedang, 2 tinggi; kritis -> tinggi)
///   bit 3..4 : kelas tenggat CSS (0 biasa, 1 segera, 2 terlambat)
export fn ordexa_row_flags(pita: u32, urgensi: u32, terlambat: u32, bit_status: u32) u32 {
    var bendera: u32 = 0;
    if (bit_status == 1) bendera |= 1;

    const kelas_prioritas: u32 = switch (pita) {
        0 => 0,
        1 => 1,
        2, 3 => 2,
        else => 0,
    };
    bendera |= kelas_prioritas << 1;

    const kelas_tenggat: u32 = if (terlambat == 1) 2 else if (urgensi == 2) 1 else 0;
    bendera |= kelas_tenggat << 3;

    return bendera;
}

// ---------------------------------------------------------------------------
// Penyaringan tampilan dan urutan tampil
// ---------------------------------------------------------------------------

const LAGAK_KUNCI: usize = 4; // tenggat_detik, dibuat_ms, status, skor

fn bidangKunci(kunci: [*]const i64, tugas: u32, bidang: usize) i64 {
    return kunci[@as(usize, tugas) * LAGAK_KUNCI + bidang];
}

/// tampilan: 0 semua · 1 hari ini · 2 akan datang · 3 selesai · 4 aktif
fn cocokTampilan(kunci: [*]const i64, tugas: u32, tampilan: u32, kini: i64, offset_zona_detik: i64) bool {
    const tenggat = bidangKunci(kunci, tugas, 0);
    const status = bidangKunci(kunci, tugas, 2);
    return switch (tampilan) {
        0 => true,
        1 => status == 0 and hariLokal(tenggat, offset_zona_detik) == hariLokal(kini, offset_zona_detik),
        2 => status == 0 and tenggat >= kini,
        3 => status == 1,
        4 => status == 0,
        else => false,
    };
}

/// kunci_urut: 0 prioritas (skor turun) · 1 tenggat (naik) · 2 dibuat (turun)
fn urutSebelum(kunci: [*]const i64, a: u32, b: u32, kunci_urut: u32) bool {
    return switch (kunci_urut) {
        0 => bidangKunci(kunci, a, 3) > bidangKunci(kunci, b, 3),
        1 => bidangKunci(kunci, a, 0) < bidangKunci(kunci, b, 0),
        else => bidangKunci(kunci, a, 1) > bidangKunci(kunci, b, 1),
    };
}

fn urutIndeks(kunci: [*]const i64, indeks: []u32, kunci_urut: u32) void {
    if (indeks.len < 2) return;
    var i: usize = 1;
    while (i < indeks.len) : (i += 1) {
        const kini = indeks[i];
        var j: usize = i;
        while (j > 0 and urutSebelum(kunci, kini, indeks[j - 1], kunci_urut)) : (j -= 1) {
            indeks[j] = indeks[j - 1];
        }
        indeks[j] = kini;
    }
}

fn implFilterUrut(
    jumlah: u32,
    kunci: [*]const i64,
    cocok: [*]const u32,
    tampilan: u32,
    kunci_urut: u32,
    kini: i64,
    offset_zona_detik: i64,
    keluar: [*]u32,
) u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < jumlah) : (i += 1) {
        if (cocok[i] == 1 and cocokTampilan(kunci, i, tampilan, kini, offset_zona_detik)) {
            keluar[n] = i;
            n += 1;
        }
    }
    const n_us: usize = n;
    urutIndeks(kunci, keluar[0..n_us], kunci_urut);
    return n;
}

/// kunci: jumlah * 4 i64 (tenggat_detik, dibuat_ms, status, skor)
/// cocok: jumlah u32 (1 = tugas cocok dengan kueri pencarian)
/// keluar: hingga jumlah u32 indeks tugas dalam urutan tampil
/// Mengembalikan banyaknya tugas yang lolos penyaringan.
export fn ordexa_filter_sort(
    jumlah: u32,
    ptr_kunci: usize,
    ptr_cocok: usize,
    tampilan: u32,
    kunci_urut: u32,
    kini: i64,
    offset_zona_detik: i64,
    ptr_keluar: usize,
) u32 {
    if (jumlah == 0) return 0;
    const kunci: [*]const i64 = @ptrFromInt(ptr_kunci);
    const cocok: [*]const u32 = @ptrFromInt(ptr_cocok);
    const keluar: [*]u32 = @ptrFromInt(ptr_keluar);
    return implFilterUrut(jumlah, kunci, cocok, tampilan, kunci_urut, kini, offset_zona_detik, keluar);
}

// ---------------------------------------------------------------------------
// Sebaran kategori
// ---------------------------------------------------------------------------

/// kunci: jumlah * 2 i64 (status, id_kategori 0..4)
/// keluar: 8 i64 — untuk tiap kategori 0..4: [aktif, selesai] pada indeks
/// kategori*2 dan kategori*2+1, lalu indeks 10 = total aktif dan 11 = total
/// selesai (untuk menghitung persentase).
export fn ordexa_category_stats(jumlah: u32, ptr_kunci: usize, ptr_keluar: usize) void {
    const keluar: [*]i64 = @ptrFromInt(ptr_keluar);
    var i: usize = 0;
    while (i < 12) : (i += 1) keluar[i] = 0;
    if (jumlah == 0) return;

    const kunci: [*]const i64 = @ptrFromInt(ptr_kunci);
    i = 0;
    while (i < jumlah) : (i += 1) {
        const status = kunci[i * 2];
        var kategori: usize = @intCast(kunci[i * 2 + 1]);
        if (kategori > 4) kategori = 4; // nilai liar dipetakan ke Lainnya
        const sel: usize = if (status == 1) 1 else 0;
        keluar[kategori * 2 + sel] += 1;
        keluar[10 + sel] += 1; // indeks 10 total aktif, 11 total selesai
    }
}

// ---------------------------------------------------------------------------
// Notifikasi: pemindaian tugas mepet dan perakitan pesan pengingat
// ---------------------------------------------------------------------------
// Ordexa adalah PWA tanpa server, jadi pengingat dijadwalkan di sisi peramban.
// Inti Zig tetap memegang dua keputusan: tugas mana yang layak diberi
// notifikasi (pemindaian ambang sisa waktu) dan bagaimana bunyi pesannya
// (perakitan teks berbahasa Indonesia di sini, bukan di JavaScript).

/// kunci: jumlah * 2 i64 (tenggat_detik, status)
/// keluar: hingga `jumlah` u32 indeks tugas aktif yang sisa jamnya sudah
/// menyentuh `ambang_jam` (termasuk yang terlambat), terurut tenggat
/// terdekat lebih dulu. Mengembalikan banyaknya indeks yang ditulis.
export fn ordexa_notify_scan(jumlah: u32, ptr_kunci: usize, kini: i64, ambang_jam: i64, ptr_keluar: usize) u32 {
    if (jumlah == 0) return 0;
    const kunci: [*]const i64 = @ptrFromInt(ptr_kunci);
    const keluar: [*]u32 = @ptrFromInt(ptr_keluar);

    var n: u32 = 0;
    var i: u32 = 0;
    while (i < jumlah) : (i += 1) {
        const tenggat = kunci[i * 2];
        const status = kunci[i * 2 + 1];
        // Tugas selesai tidak perlu diingatkan lagi.
        if (status == 1) continue;
        // Sisa jam negatif (terlambat) selalu lolos supaya pengguna tahu
        // ada tenggat yang terlewat; selain itu harus menyentuh ambang.
        if (ordexa_hours_left(tenggat, kini) > ambang_jam) continue;
        // Sisip terurut menurut tenggat terdekat (daftar kecil, insertion sort).
        var j: usize = n;
        while (j > 0 and kunci[@as(usize, keluar[j - 1]) * 2] > tenggat) : (j -= 1) {
            keluar[j] = keluar[j - 1];
        }
        keluar[j] = i;
        n += 1;
    }
    return n;
}

/// Alamat penyangga isi notifikasi (dipakai JS setelah ordexa_notify_due_body).
/// Sama dengan penyangga baris karena keduanya tidak pernah dipakai bersamaan
/// dalam satu putaran dan ukurannya cukup untuk judul terpanjang sekalipun.
export fn ordexa_notify_ptr() usize {
    return @intFromPtr(&penyangga_baris);
}

/// Rakit isi notifikasi tugas mepet ke penyangga notifikasi; kembalikan
/// panjang byte hasil (0 bila penyangga tidak cukup).
///   judul              : string mentah UTF-8 di arena goresan
///   sisa_jam           : hasil ordexa_hours_left untuk tugas ini
///   tenggat, kini, tz  : konteks waktu untuk label tenggat
/// Varian dekat : "„judul“ mendekati tenggat — tinggal 2 jam lagi (Hari ini, 14.00)."
/// Varian lewat : "„judul“ melewati tenggat — terlambat 5 jam. Masih mau dikerjakan?"
export fn ordexa_notify_due_body(
    ptr_judul: usize,
    panjang_judul: u32,
    sisa_jam: i64,
    tenggat: i64,
    kini: i64,
    offset_zona_detik: i64,
) u32 {
    const judul: []const u8 = (@as([*]const u8, @ptrFromInt(ptr_judul)))[0..panjang_judul];
    var p = Penulis{ .penyangga = &penyangga_baris };
    if (!p.potongan("\u{201C}")) return 0;
    if (!p.potongan(judul)) return 0;
    if (!p.potongan("\u{201D} ")) return 0;
    if (sisa_jam >= 0) {
        if (!p.potongan("mendekati tenggat \u{2014} tinggal ")) return 0;
        if (!tulisRelatifJam(&p, sisa_jam)) return 0;
        if (!p.potongan(" (")) return 0;
        if (!tulisTenggat(&p, tenggat, kini, offset_zona_detik)) return 0;
        if (!p.potongan(").")) return 0;
    } else {
        if (!p.potongan("melewati tenggat \u{2014} ")) return 0;
        if (!tulisRelatifJam(&p, sisa_jam)) return 0;
        if (!p.potongan(". Masih mau dikerjakan?")) return 0;
    }
    return @intCast(p.n);
}

// ---------------------------------------------------------------------------
// Perakit baris tugas (HTML) di sisi mesin
// ---------------------------------------------------------------------------
// Markup satu baris daftar tugas dirakit penuh di sini, termasuk pengamanan
// HTML, pemilihan kelas CSS, label, dan format tanggal. Lapisan JS cukup
// menulis string mentah ke arena goresan lalu membaca hasil HTML jadi.

const UKURAN_PENYANGGA_BARIS: usize = 8192;
var penyangga_baris: [UKURAN_PENYANGGA_BARIS]u8 = undefined;

/// Alamat penyangga HTML baris (dipakai JS setelah ordexa_render_task_row).
export fn ordexa_row_ptr() usize {
    return @intFromPtr(&penyangga_baris);
}

/// Rakit satu baris daftar tugas menjadi HTML di penyangga baris.
///   id, judul, catatan, kategori : string mentah UTF-8 di arena goresan
///   kesulitan : 1 ringan, 2 sedang, 3 berat
///   bit_status: 0 aktif, 1 selesai
///   skor, pita, urgensi, terlambat : hasil ordexa_analyze untuk tugas ini
/// Mengembalikan panjang HTML dalam byte, atau 0 bila penyangga tidak cukup.
export fn ordexa_render_task_row(
    ptr_id: usize,
    panjang_id: u32,
    ptr_judul: usize,
    panjang_judul: u32,
    ptr_catatan: usize,
    panjang_catatan: u32,
    ptr_kategori: usize,
    panjang_kategori: u32,
    kesulitan: u32,
    bit_status: u32,
    tenggat: i64,
    kini: i64,
    offset_zona_detik: i64,
    skor: u32,
    pita: u32,
    urgensi: u32,
    terlambat: u32,
) u32 {
    const id: []const u8 = (@as([*]const u8, @ptrFromInt(ptr_id)))[0..panjang_id];
    const judul: []const u8 = (@as([*]const u8, @ptrFromInt(ptr_judul)))[0..panjang_judul];
    const catatan: []const u8 = (@as([*]const u8, @ptrFromInt(ptr_catatan)))[0..panjang_catatan];
    const kategori: []const u8 = (@as([*]const u8, @ptrFromInt(ptr_kategori)))[0..panjang_kategori];

    var p = Penulis{ .penyangga = &penyangga_baris };

    // Kelas CSS dipadatkan lewat penanda baris yang sudah diuji tersendiri.
    const bendera = ordexa_row_flags(pita, urgensi, terlambat, bit_status);
    const kelas_tenggat: []const u8 = switch ((bendera >> 3) & 3) {
        1 => " soon",
        2 => " late",
        else => "",
    };
    const kelas_prioritas: []const u8 = switch ((bendera >> 1) & 3) {
        1 => "medium",
        2 => "high",
        else => "low",
    };
    const kelas_kesulitan: []const u8 = switch (kesulitan) {
        1 => "difficulty-light",
        2 => "difficulty-medium",
        3 => "difficulty-heavy",
        else => "difficulty-light",
    };

    // Pembuka baris + kolom utama.
    if (!p.potongan("<div class=\"task-row\" data-id=\"")) return 0;
    if (!p.terlindung(id)) return 0;
    if (!p.potongan("\"><div class=\"task-main\"><div class=\"task-title-line\"><span class=\"task-title")) return 0;
    if (bit_status == 1 and !p.potongan(" is-complete")) return 0;
    if (!p.potongan("\">")) return 0;
    if (!p.terlindung(judul)) return 0;
    if (!p.potongan("</span><span class=\"task-category\">")) return 0;
    if (!p.terlindung(kategori)) return 0;
    if (!p.potongan("</span></div>")) return 0;
    if (catatan.len > 0) {
        if (!p.potongan("<div class=\"task-description\">")) return 0;
        if (!p.terlindung(catatan)) return 0;
        if (!p.potongan("</div>")) return 0;
    }
    if (!p.potongan("</div>")) return 0;

    // Kolom kesulitan.
    if (!p.potongan("<div class=\"difficulty-cell\"><span class=\"difficulty-pill ")) return 0;
    if (!p.potongan(kelas_kesulitan)) return 0;
    if (!p.potongan("\">")) return 0;
    if (!p.potongan(ui_strings[ordexa_difficulty_label_id(kesulitan)])) return 0;
    if (!p.potongan("</span></div>")) return 0;

    // Kolom tenggat dengan tooltip sisa waktu relatif.
    if (!p.potongan("<div class=\"deadline-text")) return 0;
    if (!p.potongan(kelas_tenggat)) return 0;
    if (!p.potongan("\" title=\"")) return 0;
    if (!tulisRelatifJam(&p, ordexa_hours_left(tenggat, kini))) return 0;
    if (!p.potongan("\">")) return 0;
    if (terlambat == 1 and !p.potongan(ui_strings[S_TERLAMBAT])) return 0;
    if (!tulisTenggat(&p, tenggat, kini, offset_zona_detik)) return 0;
    if (!p.potongan("</div>")) return 0;

    // Kolom prioritas.
    if (!p.potongan("<div class=\"priority-cell\"><span class=\"priority-pill ")) return 0;
    if (!p.potongan(kelas_prioritas)) return 0;
    if (!p.potongan("\">")) return 0;
    if (!p.potongan(ui_strings[ordexa_priority_label_id(pita)])) return 0;
    if (!p.potongan(" &#183; ")) return 0;
    if (!p.angka(skor)) return 0;
    if (!p.potongan("</span></div>")) return 0;

    // Kolom aksi: menu titik tiga dengan toggle/edit/hapus.
    if (!p.potongan("<div class=\"row-actions\"><button class=\"more-button\" data-action=\"menu\" aria-label=\"")) return 0;
    if (!p.potongan(ui_strings[S_ARIA_AKSI])) return 0;
    if (!p.potongan("\">&#183;&#183;&#183;</button><div class=\"row-menu hidden\"><button data-action=\"toggle\">")) return 0;
    if (!p.potongan(ui_strings[if (bit_status == 1) S_AKSI_TANDAI_AKTIF else S_AKSI_TANDAI_SELESAI])) return 0;
    if (!p.potongan("</button><button data-action=\"edit\">")) return 0;
    if (!p.potongan(ui_strings[S_AKSI_EDIT])) return 0;
    if (!p.potongan("</button><button class=\"delete-action\" data-action=\"delete\">")) return 0;
    if (!p.potongan(ui_strings[S_AKSI_HAPUS])) return 0;
    if (!p.potongan("</button></div></div></div>")) return 0;

    return @intCast(p.n);
}

// ---------------------------------------------------------------------------
// Tes
// ---------------------------------------------------------------------------

fn sebagaiAlamat(ptr: anytype) usize {
    return @intFromPtr(ptr);
}

fn stringById(id: u32) []const u8 {
    return ui_strings[id];
}

test "kesulitan dan tenggat memengaruhi skor" {
    try expect(ordexa_score(3, 12) > ordexa_score(1, 168));
    try expect(ordexa_score(1, -1) > ordexa_score(1, 336));
}

test "keranjang urgensi" {
    try expectEqual(@as(u32, 3), ordexa_urgency(-1));
    try expectEqual(@as(u32, 2), ordexa_urgency(12));
    try expectEqual(@as(u32, 1), ordexa_urgency(48));
    try expectEqual(@as(u32, 0), ordexa_urgency(200));
}

test "persentase penyelesaian terjaga batasnya" {
    try expectEqual(@as(u32, 0), ordexa_completion_percent(0, 0));
    try expectEqual(@as(u32, 50), ordexa_completion_percent(4, 2));
    try expectEqual(@as(u32, 100), ordexa_completion_percent(4, 9));
}

test "kesulitan tak dikenal aman memakai bobot ringan" {
    try expectEqual(ordexa_score(1, 100), ordexa_score(99, 100));
    try expectEqual(@as(u32, 1), ordexa_validate(480, 1, 0));
    try expectEqual(@as(u32, 0), ordexa_validate(481, 1, 0));
}

test "validasi kaya mengembalikan id pesan yang tepat" {
    try expectEqual(@as(u32, 0), ordexa_validate_ex(10, 1000));
    try expectEqual(S_FORM_JUDUL_KOSONG, ordexa_validate_ex(0, 1000));
    try expectEqual(S_FORM_JUDUL_PANJANG, ordexa_validate_ex(481, 1000));
    try expectEqual(S_FORM_TENGGAT, ordexa_validate_ex(10, 0));
}

test "konversi tenggat menangani dekat dan lewat" {
    try expectEqual(@as(i64, 24), ordexa_hours_left(86_400, 0));
    try expectEqual(@as(i64, 0), ordexa_hours_left(3_599, 0));
    try expectEqual(@as(i64, -1), ordexa_hours_left(-1, 0));
}

test "pita prioritas mengikuti ambang skor" {
    try expectEqual(@as(u32, 0), ordexa_priority_band(41));
    try expectEqual(@as(u32, 1), ordexa_priority_band(42));
    try expectEqual(@as(u32, 2), ordexa_priority_band(65));
    try expectEqual(@as(u32, 3), ordexa_priority_band(85));
}

test "jenis tenggat mengikuti hari kalender setempat" {
    try expectEqual(@as(u32, 0), ordexa_deadline_kind(1_000, 500, 0));
    try expectEqual(@as(u32, 1), ordexa_deadline_kind(DETIK_PER_HARI + 5, 0, 0));
    try expectEqual(@as(u32, 2), ordexa_deadline_kind(3 * DETIK_PER_HARI, 0, 0));
    // UTC+7: 60000 detik adalah 23:20 setempat pada hari lokal yang sama dengan kini = 0.
    try expectEqual(@as(u32, 0), ordexa_deadline_kind(60_000, 0, 25_200));
}

test "pencarian tanpa pedulikan besar-kecil" {
    try expect(memuatKecil("Kirim Proposal Klien", "proposal"));
    try expect(memuatKecil("Kirim Proposal Klien", "KLIEN"));
    try expect(!memuatKecil("Kirim Proposal Klien", "rapat"));
    try expect(memuatKecil("abc", ""));
    try expect(!memuatKecil("ab", "abc"));
    // Byte non-ASCII dibandingkan persis.
    try expect(memuatKecil("Rapat Übung", "Ü"));
}

test "analisis massal menandai tugas aktif yang terlambat" {
    const hasil = analisaTugas(-10, 0, 1, 0);
    try expectEqual(@as(i64, -1), hasil[0]);
    try expectEqual(@as(i64, 1), hasil[4]);
    const selesai = analisaTugas(-10, 1, 1, 0);
    try expectEqual(@as(i64, 0), selesai[4]);
    const diskor = analisaTugas(3600, 0, 3, 0);
    try expect(diskor[1] > 60);
}

test "ekspor analyze menulis lima bidang per tugas" {
    const larik_masuk = [_]i64{ 3600, 0, 3, -10, 0, 1, 7 * DETIK_PER_HARI, 1, 2 };
    var larik_keluar: [15]i64 = undefined;
    ordexa_analyze(3, sebagaiAlamat(&larik_masuk), sebagaiAlamat(&larik_keluar), 0);
    try expect(larik_keluar[0 * 5 + 1] > 60); // berat + sisa 1 jam skor tinggi
    try expectEqual(@as(i64, 1), larik_keluar[1 * 5 + 4]); // tugas kedua terlambat
    try expectEqual(@as(i64, 0), larik_keluar[2 * 5 + 4]); // selesai tak pernah terlambat
}

test "ekspor stats mengagregasi ruang kerja" {
    const kunci = [_]i64{ -5, 0, 10, 1, 20, 0 };
    var larik_keluar: [5]i64 = undefined;
    ordexa_stats(3, sebagaiAlamat(&kunci), 0, sebagaiAlamat(&larik_keluar));
    try expectEqual(@as(i64, 3), larik_keluar[0]);
    try expectEqual(@as(i64, 1), larik_keluar[1]);
    try expectEqual(@as(i64, 2), larik_keluar[2]);
    try expectEqual(@as(i64, 1), larik_keluar[3]);
    try expectEqual(@as(i64, 33), larik_keluar[4]);
}

test "grafik mengelompokkan tugas aktif per urgensi dan kesulitan" {
    // t0: 1 jam lagi, aktif, berat  -> grup 0 mendesak, tingkat 0 berat
    // t1: 48 jam lagi, aktif, ringan -> grup 1 segera, tingkat 2 ringan
    // t2: 30 hari lagi, aktif, sedang -> grup 2 nanti, tingkat 1 sedang
    // t3: selesai, apa pun            -> diabaikan
    // t4: terlambat, aktif, sedang    -> grup 0 mendesak, tingkat 1 sedang
    const kunci = [_]i64{
        3600, 0, 3,
        48 * 3600, 0, 1,
        30 * 24 * 3600, 0, 2,
        3600, 1, 3,
        -100, 0, 2,
    };
    var keluar: [10]i64 = undefined;
    ordexa_chart(5, sebagaiAlamat(&kunci), 0, sebagaiAlamat(&keluar));
    try expectEqual(@as(i64, 1), keluar[0 * 3 + 0]); // mendesak + berat
    try expectEqual(@as(i64, 1), keluar[0 * 3 + 1]); // mendesak + sedang (terlambat)
    try expectEqual(@as(i64, 0), keluar[0 * 3 + 2]); // mendesak + ringan
    try expectEqual(@as(i64, 1), keluar[1 * 3 + 2]); // segera + ringan
    try expectEqual(@as(i64, 1), keluar[2 * 3 + 1]); // nanti + sedang
    try expectEqual(@as(i64, 1), keluar[9]); // maksimum batang
}

test "grafik tanpa tugas menghasilkan nol" {
    var keluar: [10]i64 = undefined;
    ordexa_chart(0, 0, 0, sebagaiAlamat(&keluar));
    var i: usize = 0;
    while (i < 10) : (i += 1) try expectEqual(@as(i64, 0), keluar[i]);
}

test "penanda baris memadatkan kelas CSS" {
    // selesai, pita kritis (-> tinggi), terlambat
    const f1 = ordexa_row_flags(3, 3, 1, 1);
    try expect(f1 & 1 == 1);
    try expectEqual(@as(u32, 2), (f1 >> 1) & 3);
    try expectEqual(@as(u32, 2), (f1 >> 3) & 3);
    // aktif, pita sedang, urgensi mendesak tapi belum terlambat
    const f2 = ordexa_row_flags(1, 2, 0, 0);
    try expect(f2 & 1 == 0);
    try expectEqual(@as(u32, 1), (f2 >> 1) & 3);
    try expectEqual(@as(u32, 1), (f2 >> 3) & 3);
    // aktif, pita rendah, santai
    const f3 = ordexa_row_flags(0, 0, 0, 0);
    try expectEqual(@as(u32, 0), f3);
}

test "tabel string UI utuh dan berbahasa Indonesia" {
    try expectEqual(@as(u32, ui_strings.len), ordexa_string_count());
    try expect(ordexa_string_ptr(0) != 0);
    try expectEqual(@as(usize, 0), ordexa_string_ptr(ordexa_string_count()));
    try expectEqual(@as(u32, 0), ordexa_string_len(999));
    // Label kesulitan.
    try expectEqualStrings("Ringan", stringById(ordexa_difficulty_label_id(1)));
    try expectEqualStrings("Sedang", stringById(ordexa_difficulty_label_id(2)));
    try expectEqualStrings("Berat", stringById(ordexa_difficulty_label_id(3)));
    try expectEqualStrings("Ringan", stringById(ordexa_difficulty_label_id(9)));
    // Label pita prioritas.
    try expectEqualStrings("Rendah", stringById(ordexa_priority_label_id(0)));
    try expectEqualStrings("Kritis", stringById(ordexa_priority_label_id(3)));
    // Label jenis tenggat.
    try expectEqualStrings("Hari ini", stringById(ordexa_kind_label_id(0)));
    try expectEqualStrings("Besok", stringById(ordexa_kind_label_id(1)));
    // Pesan konfirmasi hapus tersambung rapi.
    try expectEqualStrings("Hapus \"", stringById(S_HAPUS_A));
    try expectEqualStrings("\"? Tindakan ini tidak dapat dibatalkan.", stringById(S_HAPUS_B));
}

test "pemformat pesan mengganti penanda dengan angka" {
    try expectEqual(@as(u32, 0), ordexa_format_message(99, 1, 1));
    try expectEqual(@as(u32, 0), ordexa_format_message(150, 1, 1));

    const panjang1 = ordexa_format_message(M_IMPOR_OK, 12, 0);
    try expectEqualStrings("12 tugas berhasil diimpor.", penyangga_format[0..panjang1]);

    const panjang2 = ordexa_format_message(M_IMPOR_KONFIRMASI, 7, 3);
    try expectEqualStrings(
        "Cadangan berisi 7 tugas dan akan menggantikan 3 tugas saat ini. Lanjutkan?",
        penyangga_format[0..panjang2],
    );

    // Angka negatif ditangani tanpa kepanjangan penyangga.
    const panjang3 = ordexa_format_message(M_IMPOR_OK, -5, 0);
    try expectEqualStrings("-5 tugas berhasil diimpor.", penyangga_format[0..panjang3]);
}

test "penyaringan dan urutan menyusun tugas aktif menurut prioritas" {
    // tugas 0: tenggat 100, dibuat 5, aktif, skor 42
    // tugas 1: tenggat -10, dibuat 9, aktif, skor 90
    // tugas 2: tenggat 200, dibuat 1, selesai, skor 10
    const kunci = [_]i64{ 100, 5, 0, 42, -10, 9, 0, 90, 200, 1, 1, 10 };
    const cocok = [_]u32{ 1, 1, 1 };
    var larik_keluar: [3]u32 = undefined;

    const aktif = implFilterUrut(3, &kunci, &cocok, 4, 0, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 2), aktif);
    try expectEqual(@as(u32, 1), larik_keluar[0]); // skor tertinggi lebih dulu
    try expectEqual(@as(u32, 0), larik_keluar[1]);

    const selesai = implFilterUrut(3, &kunci, &cocok, 3, 0, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 1), selesai);
    try expectEqual(@as(u32, 2), larik_keluar[0]);

    const menurut_tenggat = implFilterUrut(3, &kunci, &cocok, 0, 1, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 3), menurut_tenggat);
    try expectEqual(@as(u32, 1), larik_keluar[0]); // tenggat terdekat lebih dulu

    const menurut_dibuat = implFilterUrut(3, &kunci, &cocok, 0, 2, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 3), menurut_dibuat);
    try expectEqual(@as(u32, 1), larik_keluar[0]); // terbaru lebih dulu

    const tak_cocok = [_]u32{ 1, 0, 1 };
    const tercari = implFilterUrut(3, &kunci, &tak_cocok, 0, 0, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 2), tercari);
    try expectEqual(@as(u32, 0), larik_keluar[0]);
    try expectEqual(@as(u32, 2), larik_keluar[1]);
}

test "tampilan hari ini mengikuti hari kalender setempat" {
    // kini = 0 dengan UTC+7: hari lokal 0 merentang -25200..61199.
    const kunci = [_]i64{ 60_000, 5, 0, 42, -20_000, 9, 0, 90, 100_000, 1, 0, 10 };
    const cocok = [_]u32{ 1, 1, 1 };
    var larik_keluar: [3]u32 = undefined;
    const hari_ini = implFilterUrut(3, &kunci, &cocok, 1, 0, 0, 25_200, &larik_keluar);
    try expectEqual(@as(u32, 2), hari_ini);
    try expectEqual(@as(u32, 1), larik_keluar[0]); // tugas skor 90 juga jatuh tempo hari ini
    try expectEqual(@as(u32, 0), larik_keluar[1]);
}

test "tampilan akan datang hanya menyimpan tugas aktif masa depan" {
    const kunci = [_]i64{ -5, 5, 0, 42, 50, 9, 0, 90, 200, 1, 1, 10 };
    const cocok = [_]u32{ 1, 1, 1 };
    var larik_keluar: [3]u32 = undefined;
    const akan_datang = implFilterUrut(3, &kunci, &cocok, 2, 1, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 1), akan_datang);
    try expectEqual(@as(u32, 1), larik_keluar[0]);
}

test "arena goresan membagikan memori sejajar dan terbatas" {
    ordexa_scratch_reset();
    const a = ordexa_scratch_alloc(10);
    const b = ordexa_scratch_alloc(10);
    try expect(a != 0 and b != 0);
    try expect(b >= a + 10);
    try expect(b % 16 == 0);
    ordexa_scratch_reset();
    const raksasa = ordexa_scratch_alloc(1024 * 1024);
    try expectEqual(@as(usize, 0), raksasa);
    ordexa_scratch_reset();
    try expect(ordexa_scratch_alloc(4) != 0);
}

// ---------------------------------------------------------------------------
// Tes kalender dan format tanggal
// ---------------------------------------------------------------------------

test "konversi hari ke tanggal sipil pada titik penting kalender" {
    // Epoch itu sendiri.
    var t = tanggalSipil(0);
    try expectEqual(@as(i64, 1970), t.tahun);
    try expectEqual(@as(u32, 1), t.bulan);
    try expectEqual(@as(u32, 1), t.hari);

    // 2024-02-29 (hari 19782) adalah kabisat empat tahunan.
    t = tanggalSipil(19_782);
    try expectEqual(@as(i64, 2024), t.tahun);
    try expectEqual(@as(u32, 2), t.bulan);
    try expectEqual(@as(u32, 29), t.hari);

    // 2000-02-29 (hari 11016) adalah kabisat abad yang habis dibagi 400.
    t = tanggalSipil(11_016);
    try expectEqual(@as(i64, 2000), t.tahun);
    try expectEqual(@as(u32, 2), t.bulan);
    try expectEqual(@as(u32, 29), t.hari);

    // 2100 bukan kabisat: Februari berakhir di 28 (hari 47540).
    t = tanggalSipil(47_540);
    try expectEqual(@as(i64, 2100), t.tahun);
    try expectEqual(@as(u32, 2), t.bulan);
    try expectEqual(@as(u32, 28), t.hari);
    t = tanggalSipil(47_541);
    try expectEqual(@as(u32, 3), t.bulan);
    try expectEqual(@as(u32, 1), t.hari);

    // Tanggal sebelum epoch tetap benar (hari -1 = 1969-12-31).
    t = tanggalSipil(-1);
    try expectEqual(@as(i64, 1969), t.tahun);
    try expectEqual(@as(u32, 12), t.bulan);
    try expectEqual(@as(u32, 31), t.hari);
}

test "panjang bulan sepanjang setahun non-kabisat konsisten" {
    // 2023-01-01 adalah hari 19358 sejak epoch.
    const panjang_bulan = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var z: i64 = 19_358;
    var bulan: usize = 0;
    while (bulan < 12) : (bulan += 1) {
        var hari: u32 = 1;
        while (hari <= panjang_bulan[bulan]) : (hari += 1) {
            const t = tanggalSipil(z);
            try expectEqual(@as(i64, 2023), t.tahun);
            try expectEqual(@as(u32, @intCast(bulan + 1)), t.bulan);
            try expectEqual(hari, t.hari);
            z += 1;
        }
    }
    // Setelah 365 hari kita berada di 2024-01-01.
    const akhir = tanggalSipil(z);
    try expectEqual(@as(i64, 2024), akhir.tahun);
    try expectEqual(@as(u32, 1), akhir.bulan);
}

test "indeks hari dalam minggu mengikuti kenyataan historis" {
    // 1970-01-01 jatuh di Kamis (indeks 4).
    try expectEqual(@as(u32, 4), indeksHari(0));
    try expectEqualStrings("Kam", NAMA_HARI[indeksHari(0)]);
    // 2000-01-01 jatuh di Sabtu.
    try expectEqualStrings("Sab", NAMA_HARI[indeksHari(10_957)]);
    // 2024-02-29 jatuh di Kamis.
    try expectEqualStrings("Kam", NAMA_HARI[indeksHari(19_782)]);
    // Indeks hari berputar tepat tujuh hari sekali.
    var z: i64 = -100;
    while (z < 500) : (z += 1) {
        try expectEqual(indeksHari(z), indeksHari(z + 7));
    }
}

test "format label tenggat menutup hari ini, besok, kemarin, dan jauh" {
    // kini = 0 (Kamis, 1 Jan 1970, 00.00 UTC).
    var panjang = ordexa_format_deadline(3600, 0, 0);
    try expectEqualStrings("Hari ini, 01.00", penyangga_format[0..panjang]);

    panjang = ordexa_format_deadline(DETIK_PER_HARI + 7200, 0, 0);
    try expectEqualStrings("Besok, 02.00", penyangga_format[0..panjang]);

    panjang = ordexa_format_deadline(3 * DETIK_PER_HARI + 36_000, 0, 0);
    try expectEqualStrings("4 Jan, 10.00", penyangga_format[0..panjang]);

    panjang = ordexa_format_deadline(-3600, 0, 0);
    try expectEqualStrings("Kemarin, 23.00", penyangga_format[0..panjang]);

    // Zona UTC+7: 60000 detik masih hari lokal yang sama dengan kini = 0.
    panjang = ordexa_format_deadline(60_000, 0, 25_200);
    try expectEqualStrings("Hari ini, 23.40", penyangga_format[0..panjang]);
}

test "format label tanggal bilah atas membentuk hari dan bulan Indonesia" {
    var panjang = ordexa_format_date_label(0, 0);
    try expectEqualStrings("Kam, 1 Jan", penyangga_format[0..panjang]);

    // Hari 19782 = 2024-02-29 (Kamis).
    panjang = ordexa_format_date_label(19_782 * DETIK_PER_HARI + 5000, 0);
    try expectEqualStrings("Kam, 29 Feb", penyangga_format[0..panjang]);

    // Zona UTC+7 menggeser hari setempat tetapi label tetap benar.
    panjang = ordexa_format_date_label(0, 25_200);
    try expectEqualStrings("Kam, 1 Jan", penyangga_format[0..panjang]);
}

test "format sisa waktu relatif untuk seluruh keranjang" {
    var panjang = ordexa_format_relative(2);
    try expectEqualStrings("2 jam lagi", penyangga_format[0..panjang]);

    panjang = ordexa_format_relative(48);
    try expectEqualStrings("2 hari lagi", penyangga_format[0..panjang]);

    panjang = ordexa_format_relative(-5);
    try expectEqualStrings("terlambat 5 jam", penyangga_format[0..panjang]);

    panjang = ordexa_format_relative(0);
    try expectEqualStrings("kurang dari satu jam lagi", penyangga_format[0..panjang]);

    panjang = ordexa_format_relative(24 * 364);
    try expectEqualStrings("364 hari lagi", penyangga_format[0..panjang]);

    panjang = ordexa_format_relative(24 * 365);
    try expectEqualStrings("lebih dari setahun lagi", penyangga_format[0..panjang]);
}

test "format nilai bawaan bidang datetime-local" {
    // kini = 0 UTC, tambah 24 jam, zona nol -> 1970-01-02 pukul 00.00.
    var panjang = ordexa_format_input_deadline(0, 0, 24);
    try expectEqualStrings("1970-01-02T00:00", penyangga_format[0..panjang]);

    // Zona UTC+7: tengah malam setempat menjadi 07.00 UTC hari yang sama.
    panjang = ordexa_format_input_deadline(0, 25_200, 24);
    try expectEqualStrings("1970-01-02T07:00", penyangga_format[0..panjang]);

    // Tengah malam tahun baru bergulir ke hari berikutnya.
    panjang = ordexa_format_input_deadline(1_735_689_600, 0, 24);
    try expectEqualStrings("2025-01-02T00:00", penyangga_format[0..panjang]);
}

test "penulis penyangga menolak tulisan melebihi kapasitas" {
    var kecil: [3]u8 = undefined;
    var p = Penulis{ .penyangga = &kecil };
    try expect(p.potongan("abc"));
    try expect(!p.potongan("d")); // penuh tepat di batas
    try expectEqual(@as(usize, 3), p.n);

    // Pengamanan HTML mengganti kelima karakter berbahaya.
    var aman: [64]u8 = undefined;
    var q = Penulis{ .penyangga = &aman };
    try expect(q.terlindung("<a href=\"x\">&'</a>"));
    try expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;", aman[0..q.n]);

    // Angka dan jam dua digit dengan pemisah titik.
    var r = Penulis{ .penyangga = &aman };
    try expect(r.angka(@as(i64, -123)));
    try expectEqualStrings("-123", aman[0..r.n]);
    var s = Penulis{ .penyangga = &aman };
    try expect(s.jam(9 * 3600 + 5 * 60));
    try expectEqualStrings("09.05", aman[0..s.n]);
}

// ---------------------------------------------------------------------------
// Tes perakit baris tugas
// ---------------------------------------------------------------------------

fn alamatString(teks: []const u8) usize {
    return @intFromPtr(teks.ptr);
}

test "perakit baris menghasilkan HTML lengkap dan terlindung" {
    const id = "t-1";
    const judul = "Rapat <klien> & \"presentasi\"";
    const catatan = "Bawa <b>slide</b>";
    const kategori = "Kerja";

    // Tugas aktif, sedang, jatuh tempo 1 jam lagi (urgensi mendesak, skor tinggi).
    const panjang = ordexa_render_task_row(
        alamatString(id),        id.len,
        alamatString(judul),     judul.len,
        alamatString(catatan),   catatan.len,
        alamatString(kategori),  kategori.len,
        2,   // kesulitan sedang
        0,   // aktif
        3600, // tenggat satu jam lagi
        0,   // kini
        0,   // zona UTC
        76,  // skor
        2,   // pita tinggi
        2,   // urgensi mendesak
        0,   // belum terlambat
    );
    try expect(panjang > 0);
    const html = penyangga_baris[0..panjang];

    // Struktur pembuka dan penutup utuh.
    try expect(std.mem.startsWith(u8, html, "<div class=\"task-row\" data-id=\"t-1\">"));
    try expect(std.mem.endsWith(u8, html, "</button></div></div></div>"));

    // Judul terlindung penuh, tidak ada tag mentah yang lolos.
    try expect(std.mem.indexOf(u8, html, "&lt;klien&gt;") != null);
    try expect(std.mem.indexOf(u8, html, "&amp;") != null);
    try expect(std.mem.indexOf(u8, html, "&quot;presentasi&quot;") != null);
    try expect(std.mem.indexOf(u8, html, "<klien>") == null);
    try expect(std.mem.indexOf(u8, html, "<b>slide</b>") == null);
    try expect(std.mem.indexOf(u8, html, "&lt;b&gt;slide&lt;/b&gt;") != null);

    // Kelas CSS dan label sesuai keputusan mesin.
    try expect(std.mem.indexOf(u8, html, "difficulty-pill difficulty-medium") != null);
    try expect(std.mem.indexOf(u8, html, "priority-pill high") != null);
    try expect(std.mem.indexOf(u8, html, "deadline-text soon") != null);
    try expect(std.mem.indexOf(u8, html, "Tinggi &#183; 76") != null);
    try expect(std.mem.indexOf(u8, html, "Hari ini, 01.00") != null);
    try expect(std.mem.indexOf(u8, html, "title=\"1 jam lagi\"") != null);
    try expect(std.mem.indexOf(u8, html, "data-action=\"toggle\">Tandai selesai") != null);
    try expect(std.mem.indexOf(u8, html, "is-complete") == null);
}

test "perakit baris menandai tugas selesai dan terlambat" {
    const id = "t-2";
    const judul = "Kirim laporan";
    const kosong = "";

    const panjang = ordexa_render_task_row(
        alamatString(id),     id.len,
        alamatString(judul),  judul.len,
        alamatString(kosong), 0,
        alamatString(kosong), 0,
        1,      // ringan
        1,      // selesai
        -7200,  // sudah lewat dua jam
        0,
        0,
        60, // skor
        1,  // pita sedang
        3,  // urgensi terlambat
        1,  // terlambat
    );
    try expect(panjang > 0);
    const html = penyangga_baris[0..panjang];

    try expect(std.mem.indexOf(u8, html, "task-title is-complete") != null);
    try expect(std.mem.indexOf(u8, html, "deadline-text late") != null);
    try expect(std.mem.indexOf(u8, html, "Terlambat · Kemarin, 22.00") != null);
    try expect(std.mem.indexOf(u8, html, "title=\"terlambat 2 jam\"") != null);
    try expect(std.mem.indexOf(u8, html, "data-action=\"toggle\">Tandai aktif") != null);
    // Catatan kosong tidak menulis elemen deskripsi.
    try expect(std.mem.indexOf(u8, html, "task-description") == null);
}

test "perakit baris menolak masukan yang melampaui penyangga" {
    // Catatan berisi 9000 byte '&' akan meledak menjadi 45000 byte entitas.
    var raksasa: [9000]u8 = undefined;
    @memset(&raksasa, '&');
    const panjang = ordexa_render_task_row(
        alamatString("t-3"), 3,
        alamatString("x"),   1,
        alamatString(&raksasa), raksasa.len,
        alamatString("y"),   1,
        1, 0, 3600, 0, 0, 10, 0, 2, 0,
    );
    try expectEqual(@as(u32, 0), panjang);
}

// ---------------------------------------------------------------------------
// Tes sifat menyeluruh mesin skor dan penyaringan
// ---------------------------------------------------------------------------

test "skor tidak pernah turun ketika waktu makin sempit" {
    // Titik batas seluruh keranjang urgensi, dari terlambat sampai sangat longgar.
    const ambang_waktu = [_]i64{ -1000, -1, 0, 1, 6, 7, 24, 25, 72, 73, 168, 169, 336, 337, 10_000 };
    var kesulitan: u32 = 1;
    while (kesulitan <= 3) : (kesulitan += 1) {
        var i: usize = 0;
        while (i + 1 < ambang_waktu.len) : (i += 1) {
            try expect(ordexa_score(kesulitan, ambang_waktu[i]) >= ordexa_score(kesulitan, ambang_waktu[i + 1]));
        }
    }
    // Kesulitan lebih berat selalu memberi skor lebih besar pada sisa waktu sama.
    var jam: i64 = -200;
    while (jam <= 800) : (jam += 61) {
        try expect(ordexa_score(1, jam) < ordexa_score(2, jam));
        try expect(ordexa_score(2, jam) < ordexa_score(3, jam));
        try expect(ordexa_score(3, jam) <= SKOR_MAKS);
    }
}

test "pita prioritas dan penanda baris konsisten pada seluruh rentang skor" {
    var skor: u32 = 0;
    while (skor <= 100) : (skor += 1) {
        const pita = ordexa_priority_band(skor);
        // Pita meningkat monoton terhadap skor.
        try expect(pita >= ordexa_priority_band(if (skor > 0) skor - 1 else 0));
        // Kelas prioritas CSS dari penanda baris tidak pernah melebihi 'tinggi'.
        const bendera = ordexa_row_flags(pita, 0, 0, 0);
        try expect((bendera >> 1) & 3 <= 2);
        // Status selesai hanya menggeser bit pencoret, tidak mengubah kelas lain.
        const bendera_selesai = ordexa_row_flags(pita, 0, 0, 1);
        try expectEqual(bendera | 1, bendera_selesai);
    }
}

test "urutan sisipan menjaga urutan relatif tugas dengan kunci sama" {
    // Tiga tugas dengan skor sama: urutan masukan harus dipertahankan (stabil).
    const kunci = [_]i64{
        100, 1, 0, 50,
        200, 2, 0, 50,
        300, 3, 0, 50,
    };
    const cocok = [_]u32{ 1, 1, 1 };
    var larik_keluar: [3]u32 = undefined;
    const hasil = implFilterUrut(3, &kunci, &cocok, 4, 0, 0, 0, &larik_keluar);
    try expectEqual(@as(u32, 3), hasil);
    try expectEqual(@as(u32, 0), larik_keluar[0]);
    try expectEqual(@as(u32, 1), larik_keluar[1]);
    try expectEqual(@as(u32, 2), larik_keluar[2]);
}

test "tabel string tampilan daftar lengkap dan siap dipakai" {
    try expectEqualStrings("Semua tugas", stringById(S_VIEW_SEMUA_JUDUL));
    try expectEqualStrings("Cari, saring, dan urutkan seluruh tugas Anda.", stringById(S_VIEW_SEMUA_SUB));
    try expectEqualStrings("Hari ini", stringById(S_VIEW_HARI_INI_JUDUL));
    try expectEqualStrings("Tugas yang jatuh tempo hari ini.", stringById(S_VIEW_HARI_INI_SUB));
    try expectEqualStrings("Akan datang", stringById(S_VIEW_DATANG_JUDUL));
    try expectEqualStrings("Tugas aktif dengan tenggat di masa depan.", stringById(S_VIEW_DATANG_SUB));
    try expectEqualStrings("Selesai", stringById(S_VIEW_SELESAI_JUDUL));
    try expectEqualStrings("Tugas yang sudah Anda selesaikan.", stringById(S_VIEW_SELESAI_SUB));
    try expectEqualStrings("Tidak ada tugas yang cocok.", stringById(S_KOSONG_LIST_JUDUL));
    try expectEqualStrings("Ubah kata kunci pencarian atau tambahkan tugas baru.", stringById(S_KOSONG_LIST_SUB));
    try expectEqualStrings("Tambah tugas", stringById(S_BUAT_TUGAS));
    try expectEqualStrings("Belum ada tugas.", stringById(S_KOSONG_FOKUS_JUDUL));
    try expectEqualStrings("Tambahkan tugas untuk mulai memantau prioritas.", stringById(S_KOSONG_FOKUS_SUB));
}

test "grafik melaporkan maksimum dengan benar saat ada seri" {
    // Dua batang berjumlah sama: maksimum harus mengikuti nilai itu.
    const kunci = [_]i64{
        3600, 0, 3, // mendesak + berat
        -100, 0, 3, // terlambat -> mendesak + berat
        48 * 3600, 0, 1, // segera + ringan
    };
    var keluar: [10]i64 = undefined;
    ordexa_chart(3, sebagaiAlamat(&kunci), 0, sebagaiAlamat(&keluar));
    try expectEqual(@as(i64, 2), keluar[0]);
    try expectEqual(@as(i64, 2), keluar[9]);
}

test "statistik dengan seluruh tugas selesai tidak menghitung terlambat" {
    const kunci = [_]i64{ -5, 1, -100, 1, -999, 1 };
    var keluar: [5]i64 = undefined;
    ordexa_stats(3, sebagaiAlamat(&kunci), 0, sebagaiAlamat(&keluar));
    try expectEqual(@as(i64, 3), keluar[0]);
    try expectEqual(@as(i64, 3), keluar[1]);
    try expectEqual(@as(i64, 0), keluar[2]);
    try expectEqual(@as(i64, 0), keluar[3]);
    try expectEqual(@as(i64, 100), keluar[4]);
}

// ---------------------------------------------------------------------------
// Tes konversi kalender bolak-balik dan sebaran kategori
// ---------------------------------------------------------------------------

test "konversi kalender bolak-balik sepuluh tahun penuh" {
    // 2020..2030 mencakup kabisat 2020, 2024, 2028 dan batas tahun.
    const panjang_bulan = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var tahun: i64 = 2020;
    while (tahun < 2030) : (tahun += 1) {
        const kabisat = (@mod(tahun, 4) == 0 and @mod(tahun, 100) != 0) or @mod(tahun, 400) == 0;
        var bulan: u32 = 1;
        while (bulan <= 12) : (bulan += 1) {
            const hari_maks = if (bulan == 2 and kabisat) 29 else panjang_bulan[bulan - 1];
            var hari: u32 = 1;
            while (hari <= hari_maks) : (hari += 1) {
                const z = hariDariTanggal(tahun, bulan, hari);
                const t = tanggalSipil(z);
                try expectEqual(tahun, t.tahun);
                try expectEqual(bulan, t.bulan);
                try expectEqual(hari, t.hari);
            }
        }
    }
    // Titik acuan lintas era: 1970-01-01 dan 2000-03-01.
    try expectEqual(@as(i64, 0), hariDariTanggal(1970, 1, 1));
    try expectEqual(@as(i64, 11_017), hariDariTanggal(2000, 3, 1));
}

test "konversi kalender acak deterministik tetap bolak-balik" {
    // Generator LCG seed tetap: uji ribuan sampel acak tanpa kebutuhan pustaka acak.
    var keadaan: u64 = 0x4f5a_4932_7d1e_8b6c;
    var iterasi: usize = 0;
    while (iterasi < 2000) : (iterasi += 1) {
        keadaan = keadaan *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        const tahun = @mod(@as(i64, @bitCast(keadaan >> 33)), 300) + 1900; // 1900..2199
        const bulan: u32 = @intCast(@mod(@as(i64, @bitCast(keadaan >> 16)), 12) + 1);
        const hari: u32 = @intCast(@mod(@as(i64, @bitCast(keadaan)), 28) + 1);
        const t = tanggalSipil(hariDariTanggal(tahun, bulan, hari));
        try expectEqual(tahun, t.tahun);
        try expectEqual(bulan, t.bulan);
        try expectEqual(hari, t.hari);
    }
}

test "format tenggat menuliskan tahun hanya saat berbeda tahun" {
    // kini = 0 (1970-01-01). Tenggat 400 hari kemudian jatuh di 1971.
    var panjang = ordexa_format_deadline(400 * DETIK_PER_HARI + 36_000, 0, 0);
    try expectEqualStrings("5 Feb 1971, 10.00", penyangga_format[0..panjang]);
    // 30 hari kemudian masih 1970: tahun tidak ditulis.
    panjang = ordexa_format_deadline(30 * DETIK_PER_HARI + 36_000, 0, 0);
    try expectEqualStrings("31 Jan, 10.00", penyangga_format[0..panjang]);
}

test "sebaran kategori menghitung aktif dan selesai per kategori" {
    // (status, kategori): aktif-Belajar, selesai-Belajar, aktif-Kerja,
    // aktif-LainNYA via nilai liar 99, selesai-Pribadi.
    const kunci = [_]i64{ 0, 0, 1, 0, 0, 1, 0, 99, 1, 2 };
    var keluar: [12]i64 = undefined;
    ordexa_category_stats(5, sebagaiAlamat(&kunci), sebagaiAlamat(&keluar));
    try expectEqual(@as(i64, 1), keluar[0]); // Belajar aktif
    try expectEqual(@as(i64, 1), keluar[1]); // Belajar selesai
    try expectEqual(@as(i64, 1), keluar[2]); // Kerja aktif
    try expectEqual(@as(i64, 0), keluar[3]); // Kerja selesai
    try expectEqual(@as(i64, 0), keluar[4]); // Pribadi aktif
    try expectEqual(@as(i64, 1), keluar[5]); // Pribadi selesai
    try expectEqual(@as(i64, 1), keluar[8]); // Lainnya aktif (nilai liar)
    try expectEqual(@as(i64, 3), keluar[10]); // total aktif
    try expectEqual(@as(i64, 2), keluar[11]); // total selesai

    // Tanpa tugas seluruh keluaran nol.
    ordexa_category_stats(0, 0, sebagaiAlamat(&keluar));
    var i: usize = 0;
    while (i < 12) : (i += 1) try expectEqual(@as(i64, 0), keluar[i]);
}

test "label kategori dan versi inti tersedia di tabel string" {
    try expectEqualStrings("Belajar", stringById(ordexa_category_label_id(0)));
    try expectEqualStrings("Kerja", stringById(ordexa_category_label_id(1)));
    try expectEqualStrings("Pribadi", stringById(ordexa_category_label_id(2)));
    try expectEqualStrings("Proyek", stringById(ordexa_category_label_id(3)));
    try expectEqualStrings("Lainnya", stringById(ordexa_category_label_id(4)));
    try expectEqualStrings("Lainnya", stringById(ordexa_category_label_id(99)));
    try expectEqualStrings("Inti Ordexa v2.1 (Zig + WebAssembly)", stringById(S_VERSI_CORE));
    try expectEqualStrings("Versi inti", stringById(S_PENGATURAN_VERSI));
    // Panjang versi konsisten dengan tabel string.
    try expectEqual(ui_strings[S_VERSI_CORE].len, ordexa_version_string());
}

test "jenis tenggat menapaki lima hari berturut tanpa lompatan" {
    // -2 kemarin .. +2 besok-lusa: 2 nanti, 1 besok, 0 hari ini, 2, 2.
    var offset_hari: i64 = -2;
    while (offset_hari <= 2) : (offset_hari += 1) {
        const jenis = ordexa_deadline_kind(offset_hari * DETIK_PER_HARI + 60, 0, 0);
        const expected: u32 = switch (offset_hari) {
            0 => 0,
            1 => 1,
            else => 2,
        };
        try expectEqual(expected, jenis);
    }
}

test "pencarian membandingkan byte tinggi secara persis" {
    // Jarum ber-diakritik tidak boleh cocok dengan huruf dasar yang sama.
    try expect(!memuatKecil("Ubung", "Ü"));
    try expect(memuatKecil("Übung", "Ü"));
    try expect(memuatKecil("Übung", "bung"));
    // Jarum lebih panjang dari jerami tetap aman.
    try expect(!memuatKecil("a", "aaaaaaaaaa"));
}

// ---------------------------------------------------------------------------
// Matriks regresi menyeluruh: seluruh kombinasi tampilan, keranjang skor,
// kelas baris, dan batas kalender diuji sistematis, bukan sepoin-sepoin.
// ---------------------------------------------------------------------------

test "matriks penyaringan x urutan menuntut seluruh lima belas kombinasi" {
    // Enam tugas dengan profil beragam:
    //   0 aktif hari ini skor 42   1 aktif terlambat skor 90
    //   2 aktif jauh skor 18       3 selesai skor 10
    //   4 aktif besok skor 55      5 aktif jauh sekali lagi skor 30
    const kunci = [_]i64{
        3600,          100, 0, 42,
        -10 * 3600,    101, 0, 90,
        30 * 86_400,   102, 0, 18,
        5 * 86_400,    103, 1, 10,
        86_400 + 60,   104, 0, 55,
        20 * 86_400,   105, 0, 30,
    };
    const cocok = [_]u32{ 1, 1, 1, 1, 1, 1 };
    var keluar: [6]u32 = undefined;

    // Tampilan: 0 semua, 1 hari ini, 2 akan datang, 3 selesai, 4 aktif.
    const jumlah_diharapkan = [_]u32{ 6, 1, 4, 1, 5 };
    var tampilan: u32 = 0;
    while (tampilan <= 4) : (tampilan += 1) {
        const n = implFilterUrut(6, &kunci, &cocok, tampilan, 0, 0, 0, &keluar);
        try expectEqual(jumlah_diharapkan[tampilan], n);
        // Urutan prioritas selalu menurun untuk tampilan yang lolos.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            try expect(bidangKunci(&kunci, keluar[i - 1], 3) >= bidangKunci(&kunci, keluar[i], 3));
        }
    }

    // Urutan: 0 prioritas (turun), 1 tenggat (naik), 2 dibuat (turun).
    const semuanya = implFilterUrut(6, &kunci, &cocok, 0, 0, 0, 0, &keluar);
    try expectEqual(@as(u32, 6), semuanya);
    try expectEqual(@as(u32, 1), keluar[0]); // skor 90

    _ = implFilterUrut(6, &kunci, &cocok, 0, 1, 0, 0, &keluar);
    try expectEqual(@as(u32, 1), keluar[0]); // tenggat paling awal (terlambat)

    _ = implFilterUrut(6, &kunci, &cocok, 0, 2, 0, 0, &keluar);
    try expectEqual(@as(u32, 5), keluar[0]); // dibuat terbaru

    // Pencarian yang menolak semua tetap menghasilkan nol pada tiap tampilan.
    const tak_cocok = [_]u32{ 0, 0, 0, 0, 0, 0 };
    tampilan = 0;
    while (tampilan <= 4) : (tampilan += 1) {
        try expectEqual(@as(u32, 0), implFilterUrut(6, &kunci, &tak_cocok, tampilan, 0, 0, 0, &keluar));
    }
}

test "matriks analisis mencakup seluruh keranjang urgensi dan kesulitan" {
    // Titik representatif tiap keranjang urgensi termasuk batas tepat.
    const sampel_jam = [_]i64{ -720, -1, 0, 1, 6, 7, 24, 25, 72, 73, 168, 169, 500 };
    var kesulitan: i64 = 1;
    while (kesulitan <= 3) : (kesulitan += 1) {
        for (sampel_jam) |jam| {
            const hasil = analisaTugas(jam * 3600, 0, kesulitan, 0);
            // Sisa jam konsisten dengan ordexa_hours_left.
            try expectEqual(ordexa_hours_left(jam * 3600, 0), hasil[0]);
            // Skor dan pita saling konsisten.
            try expectEqual(@as(i64, ordexa_priority_band(@intCast(hasil[1]))), hasil[2]);
            // Urgensi konsisten dengan definisi keranjang.
            try expectEqual(@as(i64, ordexa_urgency(hasil[0])), hasil[3]);
            // Tugas aktif terlambat tepat saat urgensi 3.
            try expectEqual(@as(i64, if (hasil[3] == 3) 1 else 0), hasil[4]);
            // Versi selesai tidak pernah terlambat.
            const selesai = analisaTugas(jam * 3600, 1, kesulitan, 0);
            try expectEqual(@as(i64, 0), selesai[4]);
        }
    }
    // Kesulitan di luar 1..3 dipetakan aman ke ringan.
    const liar = analisaTugas(3600, 0, 99, 0);
    try expectEqual(analisaTugas(3600, 0, 1, 0)[1], liar[1]);
}

test "matriks perakit baris konsisten dengan penanda baris di semua kelas" {
    const id = "m";
    const judul = "x";
    var pita: u32 = 0;
    while (pita <= 3) : (pita += 1) {
        var urgensi: u32 = 0;
        while (urgensi <= 3) : (urgensi += 1) {
            var status: u32 = 0;
            while (status <= 1) : (status += 1) {
                const terlambat: u32 = if (urgensi == 3) 1 else 0;
                const panjang = ordexa_render_task_row(
                    alamatString(id),    id.len,
                    alamatString(judul), judul.len,
                    alamatString(judul), 0,
                    alamatString(judul), 0,
                    2, status, 3600, 0, 0, 42, pita, urgensi, terlambat,
                );
                try expect(panjang > 0);
                const html = penyangga_baris[0..panjang];
                const bendera = ordexa_row_flags(pita, urgensi, terlambat, status);

                // Kelas prioritas pada HTML harus mengikuti bit penanda.
                const kelas_diharapkan = switch ((bendera >> 1) & 3) {
                    1 => "priority-pill medium",
                    2 => "priority-pill high",
                    else => "priority-pill low",
                };
                try expect(std.mem.indexOf(u8, html, kelas_diharapkan) != null);

                // Pencoret judul hanya untuk status selesai.
                const dicoret = std.mem.indexOf(u8, html, "is-complete") != null;
                try expectEqual(status == 1, dicoret);

                // Menu toggle sesuai arah status.
                const toggle = if (status == 1) "Tandai aktif" else "Tandai selesai";
                try expect(std.mem.indexOf(u8, html, toggle) != null);
            }
        }
    }
}

test "matriks grafik menempatkan seluruh dua belas kombinasi urgensi x kesulitan" {
    // Satu tugas untuk tiap keranjang urgensi (dipilih jam representatif)
    // dikali tiap kesulitan; tiap batang harus berisi tepat satu.
    const jam_per_urgensi = [_]i64{ 500 * 3600, 48 * 3600, 5 * 3600, -3600 }; // 0..3
    var kunci: [12 * 3]i64 = undefined;
    var i: usize = 0;
    for (jam_per_urgensi) |jam| {
        var kesulitan: i64 = 1;
        while (kesulitan <= 3) : (kesulitan += 1) {
            kunci[i * 3] = jam;
            kunci[i * 3 + 1] = 0; // aktif
            kunci[i * 3 + 2] = kesulitan;
            i += 1;
        }
    }
    var keluar: [10]i64 = undefined;
    ordexa_chart(12, sebagaiAlamat(&kunci), 0, sebagaiAlamat(&keluar));
    // Grup 0 mendesak menampung urgensi 2 dan 3 (enam tugas, dua per tingkat);
    // grup 1 segera dan grup 2 nanti masing-masing tiga (satu per tingkat).
    var idx: usize = 0;
    while (idx < 3) : (idx += 1) {
        try expectEqual(@as(i64, 2), keluar[idx]); // mendesak
        try expectEqual(@as(i64, 1), keluar[3 + idx]); // segera
        try expectEqual(@as(i64, 1), keluar[6 + idx]); // nanti
    }
    try expectEqual(@as(i64, 2), keluar[9]); // maksimum
}

test "grid format tenggat menapaki rentang hari lebar dengan dan tanpa zona" {
    const zona_uji = [_]i64{ -25_200, 0, 25_200 }; // UTC-7, UTC, UTC+7
    for (zona_uji) |zona| {
        var hari: i64 = -3;
        while (hari <= 40) : (hari += 1) {
            const tenggat = hari * DETIK_PER_HARI + 45_000;
            const panjang = ordexa_format_deadline(tenggat, 0, zona);
            try expect(panjang > 0);
            const teks = penyangga_format[0..panjang];
            // Label selalu diakhiri jam dua digit berpemisah titik.
            try expect(teks.len > 5);
            try expect(std.mem.indexOfScalar(u8, teks, '.') != null);
            // Struktur prefiks spesifik hanya diuji pada zona nol agar tidak
            // bergantung pada pergeseran hari kalender setempat.
            if (zona == 0) {
                if (hari == 0) {
                    try expect(std.mem.startsWith(u8, teks, "Hari ini, "));
                } else if (hari == 1) {
                    try expect(std.mem.startsWith(u8, teks, "Besok, "));
                } else if (hari == -1) {
                    try expect(std.mem.startsWith(u8, teks, "Kemarin, "));
                } else {
                    try expect(std.mem.indexOfScalar(u8, teks, ' ') != null);
                }
            }
        }
    }
}

test "jenis tenggat konsisten pada tiga zona untuk batas hari" {
    const zona_uji = [_]i64{ -25_200, 0, 25_200 };
    for (zona_uji) |zona| {
        var hari: i64 = -1;
        while (hari <= 2) : (hari += 1) {
            const jenis = ordexa_deadline_kind(hari * DETIK_PER_HARI + 60, 0, zona);
            const diharapkan: u32 = switch (hari) {
                0 => 0,
                1 => 1,
                else => 2,
            };
            try expectEqual(diharapkan, jenis);
        }
    }
}

test "pecah waktu lokal menjaga detik harian dalam rentang hari" {
    const zona_uji = [_]i64{ -25_200, -3600, 0, 3600, 25_200, 43_200 }; // hingga UTC+12
    for (zona_uji) |zona| {
        var detik: i64 = -100_000;
        while (detik <= 100_000) : (detik += 9_973) {
            const waktu = pecahWaktuLokal(detik, zona);
            try expect(waktu.detik_harian < 86_400);
            // Rekonstruksi mengembalikan waktu lokal semula.
            try expectEqual(waktu.hari * DETIK_PER_HARI + waktu.detik_harian, detik + zona);
        }
    }
}

test "tabel string seluruh ID mengembalikan alamat dan panjang positif" {
    var id: u32 = 0;
    while (id < ui_strings.len) : (id += 1) {
        try expect(ordexa_string_ptr(id) != 0);
        try expect(ordexa_string_len(id) > 0);
        // Teks tidak boleh berisi byte nol.
        const teks = ui_strings[id];
        for (teks) |b| try expect(b != 0);
    }
    // ID di luar tabel ditolak di kedua aksesor.
    try expectEqual(@as(usize, 0), ordexa_string_ptr(ui_strings.len));
    try expectEqual(@as(u32, 0), ordexa_string_len(ui_strings.len));
}

test "arena goresan tetap sejajar selama fragmentasi berulang" {
    ordexa_scratch_reset();
    var sebelumnya: usize = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const ukuran: u32 = @intCast((i * 37) % 200 + 1);
        const ptr = ordexa_scratch_alloc(ukuran);
        try expect(ptr != 0);
        try expect(ptr % 16 == 0); // selalu sejajar 16 byte
        try expect(ptr >= sebelumnya); // alokasi monoton ke atas
        sebelumnya = ptr;
    }
    ordexa_scratch_reset();
    // Setelah reset, arena bisa dipakai penuh lagi.
    try expect(ordexa_scratch_alloc(UKURAN_GORESAN - 64) != 0);
    ordexa_scratch_reset();
}

test "pemformat pesan menangani angka ekstrem tanpa kepanjangan" {
    // Angka terbesar dan terkecil i64 tetap terformat (panjang > 0).
    try expect(ordexa_format_message(M_IMPOR_OK, std.math.minInt(i64), 0) > 0);
    try expect(ordexa_format_message(M_IMPOR_OK, std.math.maxInt(i64), 0) > 0);
    // Angka nol dan hasil penggandaan penanda keduanya bekerja.
    const panjang = ordexa_format_message(M_IMPOR_KONFIRMASI, 0, 0);
    try expect(panjang > 0);
    try expect(std.mem.indexOf(u8, penyangga_format[0..panjang], "0") != null);
}

test "kalender menapaki batas tahun 1900 sampai 2200" {
    var tahun: i64 = 1900;
    while (tahun <= 2200) : (tahun += 1) {
        // 1 Januari dan 31 Desember bolak-balik setiap tahun.
        const awal = hariDariTanggal(tahun, 1, 1);
        const akhir = hariDariTanggal(tahun, 12, 31);
        const t_awal = tanggalSipil(awal);
        const t_akhir = tanggalSipil(akhir);
        try expectEqual(tahun, t_awal.tahun);
        try expectEqual(@as(u32, 1), t_awal.bulan);
        try expectEqual(@as(u32, 1), t_awal.hari);
        try expectEqual(tahun, t_akhir.tahun);
        try expectEqual(@as(u32, 12), t_akhir.bulan);
        try expectEqual(@as(u32, 31), t_akhir.hari);
        // Selisih dua tanggal dalam setahun mengikuti aturan kabisat.
        const kabisat = (@mod(tahun, 4) == 0 and @mod(tahun, 100) != 0) or @mod(tahun, 400) == 0;
        try expectEqual(@as(i64, if (kabisat) 365 else 364), akhir - awal);
    }
}

test "validasi dasar dan kaya menutup seluruh cabang batas" {
    // Validasi dasar: 1 valid, 0 ditolak.
    try expectEqual(@as(u32, 1), ordexa_validate(1, 1, 0));
    try expectEqual(@as(u32, 0), ordexa_validate(0, 1, 0)); // judul kosong
    try expectEqual(@as(u32, 0), ordexa_validate(481, 1, 0)); // judul kepanjangan
    try expectEqual(@as(u32, 0), ordexa_validate(10, 0, 0)); // tenggat epoch nol
    try expectEqual(@as(u32, 0), ordexa_validate(10, -5, 0)); // tenggat negatif

    // Validasi kaya: ID pesan yang tepat untuk tiap penolakan.
    try expectEqual(@as(u32, 0), ordexa_validate_ex(1, 1));
    try expectEqual(S_FORM_JUDUL_KOSONG, ordexa_validate_ex(0, 1));
    try expectEqual(S_FORM_JUDUL_PANJANG, ordexa_validate_ex(481, 1));
    try expectEqual(S_FORM_JUDUL_PANJANG, ordexa_validate_ex(100_000, 1));
    try expectEqual(S_FORM_TENGGAT, ordexa_validate_ex(10, 0));
    try expectEqual(S_FORM_TENGGAT, ordexa_validate_ex(10, -1));
    // Tenggat epoch nol dan negatif ditolak di kedua lapis validasi.
    try expectEqual(S_FORM_TENGGAT, ordexa_validate_ex(10, -86_400));
}

test "persentase penyelesaian grid pembagi dan batas" {
    // Pembagi umum, hasil tepat dan pembulatan ke bawah.
    try expectEqual(@as(u32, 25), ordexa_completion_percent(4, 1));
    try expectEqual(@as(u32, 33), ordexa_completion_percent(3, 1));
    try expectEqual(@as(u32, 66), ordexa_completion_percent(3, 2));
    try expectEqual(@as(u32, 75), ordexa_completion_percent(8, 6));
    try expectEqual(@as(u32, 100), ordexa_completion_percent(7, 7));
    // Nol total dan selesai melebihi total dijaga (dipotong ke total).
    try expectEqual(@as(u32, 0), ordexa_completion_percent(0, 5));
    try expectEqual(@as(u32, 100), ordexa_completion_percent(5, 999));
    // Monoton terhadap jumlah selesai.
    var selesai: u32 = 0;
    while (selesai < 10) : (selesai += 1) {
        try expect(ordexa_completion_percent(10, selesai) <= ordexa_completion_percent(10, selesai + 1));
    }
}

test "statistik matriks campuran status dan tenggat" {
    // Kombinasi: (terlambat aktif, tepat waktu aktif, selesai) x bobot berbeda.
    const kunci = [_]i64{
        -100, 0, // terlambat aktif
        0,     0, // tepat waktu aktif (tenggat kini)
        100,   0, // masa depan aktif
        -100,  1, // selesai (tidak menghitung terlambat)
        100,   1, // selesai
    };
    var keluar: [5]i64 = undefined;
    ordexa_stats(5, sebagaiAlamat(&kunci), 0, sebagaiAlamat(&keluar));
    try expectEqual(@as(i64, 5), keluar[0]);
    try expectEqual(@as(i64, 2), keluar[1]);
    try expectEqual(@as(i64, 3), keluar[2]);
    try expectEqual(@as(i64, 1), keluar[3]);
    try expectEqual(@as(i64, 40), keluar[4]);

    // Semua aktif tanpa terlambat.
    const kunci2 = [_]i64{ 10, 0, 20, 0, 30, 0 };
    ordexa_stats(3, sebagaiAlamat(&kunci2), 0, sebagaiAlamat(&keluar));
    try expectEqual(@as(i64, 0), keluar[3]);
    try expectEqual(@as(i64, 0), keluar[4]);
}

test "label jenis tenggat dan kesulitan menutup seluruh cabang" {
    // Label jenis tenggat: 0 hari ini, 1 besok, lainnya tanpa tenggat.
    try expectEqual(S_HARI_INI, ordexa_kind_label_id(0));
    try expectEqual(S_BESOK, ordexa_kind_label_id(1));
    try expectEqual(S_TANPA_TENGGAT, ordexa_kind_label_id(2));
    try expectEqual(S_TANPA_TENGGAT, ordexa_kind_label_id(99));
    // Label kesulitan: 1..3 valid, lainnya jatuh ke ringan.
    try expectEqual(S_RINGAN, ordexa_difficulty_label_id(1));
    try expectEqual(S_SEDANG, ordexa_difficulty_label_id(2));
    try expectEqual(S_BERAT, ordexa_difficulty_label_id(3));
    try expectEqual(S_RINGAN, ordexa_difficulty_label_id(0));
    try expectEqual(S_RINGAN, ordexa_difficulty_label_id(7));
    // Label pita prioritas: 0..3 valid, lainnya jatuh ke rendah.
    try expectEqual(S_RENDAH, ordexa_priority_label_id(0));
    try expectEqual(S_SEDANG, ordexa_priority_label_id(1));
    try expectEqual(S_TINGGI, ordexa_priority_label_id(2));
    try expectEqual(S_KRITIS, ordexa_priority_label_id(3));
    try expectEqual(S_RENDAH, ordexa_priority_label_id(4));
}

test "tiga ekspor agregasi sepakat soal jumlah tugas aktif" {
    // Rumpun data sama (status, tenggat, kesulitan, kategori) dilihat dari
    // tiga ekspor berbeda: jumlah aktif harus identik di ketiganya.
    // LCG deterministik agar suite tanpa kebutuhan pustaka acak.
    var keadaan: u64 = 0x1a2b_3c4d_5e6f_7081;
    const jumlah: usize = 120;
    var kunci: [jumlah * 4]i64 = undefined; // tenggat, status, kesulitan, kategori
    var i: usize = 0;
    while (i < jumlah) : (i += 1) {
        keadaan = keadaan *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        const lempar = @as(i64, @bitCast(keadaan >> 24));
        kunci[i * 4] = @mod(lempar, 60 * 86_400) - 5 * 86_400; // -5..55 hari
        kunci[i * 4 + 1] = if (@mod(lempar, 3) == 0) 1 else 0; // sepertiga selesai
        kunci[i * 4 + 2] = @mod(lempar, 3) + 1; // kesulitan 1..3
        kunci[i * 4 + 3] = @mod(@divFloor(lempar, 7), 5); // kategori 0..4
    }

    // 1) Statistik: keluar[2] = jumlah aktif (tata letak 2 field: tenggat, status).
    var kunci_stats: [jumlah * 2]i64 = undefined;
    i = 0;
    while (i < jumlah) : (i += 1) {
        kunci_stats[i * 2] = kunci[i * 4];
        kunci_stats[i * 2 + 1] = kunci[i * 4 + 1];
    }
    var keluar_stats: [5]i64 = undefined;
    ordexa_stats(jumlah, sebagaiAlamat(&kunci_stats), 0, sebagaiAlamat(&keluar_stats));

    // 2) Grafik: penjumlahan seluruh batang (indeks 0..8) = tugas aktif.
    //    Grafik memakai tata letak 3 field (tenggat, status, kesulitan).
    var kunci_chart: [jumlah * 3]i64 = undefined;
    i = 0;
    while (i < jumlah) : (i += 1) {
        kunci_chart[i * 3] = kunci[i * 4];
        kunci_chart[i * 3 + 1] = kunci[i * 4 + 1];
        kunci_chart[i * 3 + 2] = kunci[i * 4 + 2];
    }
    var keluar_chart: [10]i64 = undefined;
    ordexa_chart(jumlah, sebagaiAlamat(&kunci_chart), 0, sebagaiAlamat(&keluar_chart));
    var jumlah_batang: i64 = 0;
    i = 0;
    while (i < 9) : (i += 1) jumlah_batang += keluar_chart[i];

    // 3) Kategori: keluar[10] = total aktif.
    var kunci_kategori: [jumlah * 2]i64 = undefined;
    i = 0;
    while (i < jumlah) : (i += 1) {
        kunci_kategori[i * 2] = kunci[i * 4 + 1];
        kunci_kategori[i * 2 + 1] = kunci[i * 4 + 3];
    }
    var keluar_kategori: [12]i64 = undefined;
    ordexa_category_stats(jumlah, sebagaiAlamat(&kunci_kategori), sebagaiAlamat(&keluar_kategori));

    try expectEqual(keluar_stats[2], jumlah_batang);
    try expectEqual(keluar_stats[2], keluar_kategori[10]);
    try expectEqual(keluar_stats[0], keluar_stats[1] + keluar_stats[2]);
    try expectEqual(keluar_stats[0], keluar_kategori[10] + keluar_kategori[11]);
}

test "format relatif grid lengkap tanpa celah keranjang" {
    // Menapaki -350..+350 jam tiap 7 jam: setiap keluaran harus berawalan benar.
    var jam: i64 = -350;
    while (jam <= 350) : (jam += 7) {
        const panjang = ordexa_format_relative(jam);
        try expect(panjang > 0);
        const teks = penyangga_format[0..panjang];
        if (jam < 0) {
            try expect(std.mem.startsWith(u8, teks, "terlambat "));
        } else if (jam == 0) {
            try expect(std.mem.startsWith(u8, teks, "kurang dari satu jam"));
        } else {
            try expect(std.mem.indexOfScalar(u8, teks, ' ') != null);
            if (@abs(jam) < 48) {
                try expect(std.mem.endsWith(u8, teks, " jam lagi"));
            } else {
                try expect(std.mem.indexOf(u8, teks, " hari") != null);
            }
        }
    }
}

test "perakit baris menolak judul yang melampaui penyangga" {
    // Judul 8500 byte '&' menjadi ~42500 byte entitas: pasti ditolak utuh.
    var raksasa: [8500]u8 = undefined;
    @memset(&raksasa, '&');
    const panjang = ordexa_render_task_row(
        alamatString("t-9"), 3,
        alamatString(&raksasa), raksasa.len,
        alamatString(""),  0,
        alamatString(""),  0,
        1, 0, 3600, 0, 0, 10, 0, 2, 0,
    );
    try expectEqual(@as(u32, 0), panjang);
    // Penyangga tetap utuh dipakai lagi setelah penolakan.
    const panjang2 = ordexa_render_task_row(
        alamatString("t-9"), 3,
        alamatString("Biasa"), 5,
        alamatString(""),    0,
        alamatString(""),    0,
        1, 0, 3600, 0, 0, 10, 0, 2, 0,
    );
    try expect(panjang2 > 0);
}

test "pemindaian notifikasi memilih tugas mepet dan terlambat" {
    // kunci (tenggat, status): t0 terlambat aktif, t1 mepet aktif,
    // t2 jauh (10 hari) aktif, t3 mepet tapi selesai, t4 mepet aktif.
    const kunci = [_]i64{ -100, 0, 3600, 0, 10 * 86_400, 0, 3600, 1, 7200, 0 };
    var keluar: [5]u32 = undefined;
    const n = ordexa_notify_scan(5, sebagaiAlamat(&kunci), 0, 24, sebagaiAlamat(&keluar));
    try expectEqual(@as(u32, 3), n);
    try expectEqual(@as(u32, 0), keluar[0]); // terlambat paling depan
    try expectEqual(@as(u32, 1), keluar[1]);
    try expectEqual(@as(u32, 4), keluar[2]);

    // Ambang nol tetap menangkap yang sudah terlambat.
    var keluar2: [5]u32 = undefined;
    const n2 = ordexa_notify_scan(5, sebagaiAlamat(&kunci), 0, 0, sebagaiAlamat(&keluar2));
    try expectEqual(@as(u32, 1), n2);
    try expectEqual(@as(u32, 0), keluar2[0]);

    // Daftar kosong aman.
    try expectEqual(@as(u32, 0), ordexa_notify_scan(0, 0, 0, 24, 0));
}

test "isi notifikasi tugas mepet memuat judul dan sisa waktu" {
    const judul = "Kirim proposal klien";
    const ptr_judul = sebagaiAlamat(judul.ptr);

    const panjang1 = ordexa_notify_due_body(ptr_judul, judul.len, 2, 3 * 3600, 0, 0);
    try expect(panjang1 > 0);
    const teks1 = penyangga_baris[0..panjang1];
    try expect(std.mem.startsWith(u8, teks1, "\u{201C}Kirim proposal klien\u{201D} mendekati tenggat"));
    try expect(std.mem.indexOf(u8, teks1, "tinggal 2 jam lagi") != null);
    try expect(std.mem.indexOf(u8, teks1, "(Hari ini, 03.00)") != null);

    const panjang2 = ordexa_notify_due_body(ptr_judul, judul.len, -5, -5 * 3600, 0, 0);
    try expect(panjang2 > 0);
    const teks2 = penyangga_baris[0..panjang2];
    try expect(std.mem.indexOf(u8, teks2, "melewati tenggat") != null);
    try expect(std.mem.indexOf(u8, teks2, "terlambat 5 jam") != null);
    try expect(std.mem.indexOf(u8, teks2, "Masih mau dikerjakan?") != null);

    // Penunjuk penyangga notifikasi selalu valid dan tak nol.
    try expect(ordexa_notify_ptr() != 0);
}

test "pesan pengingat harian memilih varian sesuai beban kerja" {
    const kosong = ordexa_format_message(M_NOTIF_HARIAN_KOSONG, 0, 0);
    try expectEqualStrings("Belum ada tugas terjadwal. Tambahkan satu untuk hari ini?", penyangga_format[0..kosong]);

    const santai = ordexa_format_message(M_NOTIF_HARIAN_SANTAI, 5, 0);
    try expectEqualStrings("Ada 5 tugas aktif di Ordexa. Yang mana yang dikerjakan lebih dulu?", penyangga_format[0..santai]);

    const mepet = ordexa_format_message(M_NOTIF_HARIAN_MEPET, 5, 2);
    try expectEqualStrings("Ada 5 tugas aktif, 2 di antaranya mendekati tenggat.", penyangga_format[0..mepet]);

    // Judul notifikasi tersedia di tabel string.
    try expectEqualStrings("Sudah buka Ordexa hari ini?", stringById(S_NOTIF_HARIAN_JUDUL));
    try expectEqualStrings("Tenggat mendekat", stringById(S_NOTIF_MEPET_JUDUL));
}
