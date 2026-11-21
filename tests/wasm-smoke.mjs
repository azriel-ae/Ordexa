// Smoke test ABI WebAssembly Ordexa.
// Memuat public/ordexa-core.wasm lewat Node.js lalu memverifikasi bahwa
// seluruh ekspor inti Zig berperilaku sesuai kontrak ABI.
import fs from 'node:fs';
import assert from 'node:assert/strict';

const file = process.argv[2] || 'public/ordexa-core.wasm';
const bytes = fs.readFileSync(file);
const { instance } = await WebAssembly.instantiate(bytes, {});
const api = instance.exports;

for (const name of [
  'ordexa_hours_left', 'ordexa_score', 'ordexa_priority_band', 'ordexa_urgency',
  'ordexa_validate', 'ordexa_validate_ex', 'ordexa_completion_percent', 'ordexa_deadline_kind',
  'ordexa_string_count', 'ordexa_string_ptr', 'ordexa_string_len',
  'ordexa_difficulty_label_id', 'ordexa_priority_label_id', 'ordexa_kind_label_id',
  'ordexa_format_ptr', 'ordexa_format_message',
  'ordexa_scratch_reset', 'ordexa_scratch_alloc', 'ordexa_contains_lower',
  'ordexa_analyze', 'ordexa_stats', 'ordexa_chart', 'ordexa_row_flags', 'ordexa_filter_sort',
  'ordexa_format_deadline', 'ordexa_format_date_label', 'ordexa_format_relative',
  'ordexa_format_input_deadline', 'ordexa_render_task_row', 'ordexa_row_ptr',
  'ordexa_category_stats', 'ordexa_category_label_id', 'ordexa_version_string',
  'ordexa_notify_scan', 'ordexa_notify_due_body', 'ordexa_notify_ptr',
]) {
  assert.equal(typeof api[name], 'function', `Ekspor Zig hilang: ${name}`);
}
assert.ok(api.memory instanceof WebAssembly.Memory, 'Memori linear tidak diekspor');

// Baca string UI dari tabel string inti Zig.
const decoder = new TextDecoder('utf-8');
function bacaString(id) {
  const ptr = api.ordexa_string_ptr(id);
  const len = api.ordexa_string_len(id);
  assert.ok(ptr > 0 && len > 0, `string UI id ${id} tidak ditemukan`);
  return decoder.decode(new Uint8Array(api.memory.buffer, ptr, len));
}
assert.equal(bacaString(api.ordexa_difficulty_label_id(1)), 'Ringan');
assert.equal(bacaString(api.ordexa_difficulty_label_id(3)), 'Berat');
assert.equal(bacaString(api.ordexa_priority_label_id(3)), 'Kritis');
assert.equal(bacaString(api.ordexa_kind_label_id(0)), 'Hari ini');
assert.equal(bacaString(api.ordexa_kind_label_id(1)), 'Besok');
assert.equal(api.ordexa_string_ptr(999), 0);
assert.equal(api.ordexa_string_len(999), 0);

// Pemformat pesan ber-angka.
function bacaFormat(id, a, b) {
  const len = api.ordexa_format_message(id, BigInt(a), BigInt(b));
  assert.ok(len > 0, `pesan id ${id} gagal diformat`);
  return decoder.decode(new Uint8Array(api.memory.buffer, api.ordexa_format_ptr(), len));
}
assert.equal(bacaFormat(100, 12, 0), '12 tugas berhasil diimpor.');
assert.equal(bacaFormat(101, 7, 3), 'Cadangan berisi 7 tugas dan akan menggantikan 3 tugas saat ini. Lanjutkan?');
assert.equal(api.ordexa_format_message(99, 1n, 1n), 0);

assert.equal(api.ordexa_hours_left(86_400n, 0n), 24n);
assert.equal(api.ordexa_hours_left(-1n, 0n), -1n);
assert.ok(api.ordexa_score(3, 12n) > api.ordexa_score(1, 168n));
assert.equal(api.ordexa_priority_band(41), 0);
assert.equal(api.ordexa_priority_band(42), 1);
assert.equal(api.ordexa_priority_band(65), 2);
assert.equal(api.ordexa_priority_band(85), 3);
assert.equal(api.ordexa_urgency(-1n), 3);
assert.equal(api.ordexa_urgency(12n), 2);
assert.equal(api.ordexa_urgency(48n), 1);
assert.equal(api.ordexa_urgency(200n), 0);
assert.equal(api.ordexa_validate(8, 1n, 0n), 1);
assert.equal(api.ordexa_validate(0, 1n, 0n), 0);

// Validasi kaya mengembalikan ID pesan kesalahan (0 = valid).
assert.equal(api.ordexa_validate_ex(10, 1000n), 0);
assert.equal(bacaString(Number(api.ordexa_validate_ex(0, 1000n))), 'Judul tugas belum diisi.');
assert.ok(api.ordexa_validate_ex(0, 1000n) > 0);
assert.equal(api.ordexa_completion_percent(4, 2), 50);
assert.equal(api.ordexa_completion_percent(0, 0), 0);
assert.equal(api.ordexa_deadline_kind(500n, 100n, 0n), 0);
assert.equal(api.ordexa_deadline_kind(86_405n, 0n, 0n), 1);

// Penanda baris: bit 0 selesai, bit 1..2 kelas prioritas, bit 3..4 kelas tenggat.
assert.equal(api.ordexa_row_flags(0, 0, 0, 0), 0);
assert.equal(api.ordexa_row_flags(3, 3, 1, 1), 1 | (2 << 1) | (2 << 3));
assert.equal(api.ordexa_row_flags(1, 2, 0, 0), (1 << 1) | (1 << 3));

// Arena goresan + pencarian tanpa pedulikan besar-kecil.
api.ordexa_scratch_reset();
function tulisTeks(teks) {
  const buf = Buffer.from(teks, 'utf8');
  const ptr = api.ordexa_scratch_alloc(buf.length);
  assert.ok(ptr > 0, 'alokasi goresan gagal');
  new Uint8Array(api.memory.buffer, ptr, buf.length).set(buf);
  return { ptr, length: buf.length };
}
const jerami = tulisTeks('Kirim Proposal Klien');
const jarum = tulisTeks('proposal');
assert.equal(api.ordexa_contains_lower(jerami.ptr, jerami.length, jarum.ptr, jarum.length), 1);
const meleset = tulisTeks('rapat');
assert.equal(api.ordexa_contains_lower(jerami.ptr, jerami.length, meleset.ptr, meleset.length), 0);

// Analisis massal: 3 tugas (tenggat, status, kesulitan).
api.ordexa_scratch_reset();
const count = 3;
const inPtr = api.ordexa_scratch_alloc(count * 24);
const outPtr = api.ordexa_scratch_alloc(count * 40);
const input = new BigInt64Array(api.memory.buffer, inPtr, count * 3);
input.set([3600n, 0n, 3n, -10n, 0n, 1n, 7n * 86400n, 1n, 2n]);
api.ordexa_analyze(count, inPtr, outPtr, 0n);
const analysis = new BigInt64Array(api.memory.buffer, outPtr, count * 5);
assert.ok(analysis[0 * 5 + 1] > 60n, 'tugas berat sisa 1 jam harus diskor tinggi');
assert.equal(analysis[1 * 5 + 4], 1n, 'tugas aktif lewat tenggat harus terlambat');
assert.equal(analysis[2 * 5 + 4], 0n, 'tugas selesai tidak pernah terlambat');

// Statistik.
api.ordexa_scratch_reset();
const statsKeysPtr = api.ordexa_scratch_alloc(count * 16);
const statsOutPtr = api.ordexa_scratch_alloc(40);
const statsKeys = new BigInt64Array(api.memory.buffer, statsKeysPtr, count * 2);
statsKeys.set([3600n, 0n, -10n, 0n, 7n * 86400n, 1n]);
api.ordexa_stats(count, statsKeysPtr, 0n, statsOutPtr);
const stats = new BigInt64Array(api.memory.buffer, statsOutPtr, 5);
assert.deepEqual(Array.from(stats, Number), [3, 1, 2, 1, 33]);

// Grafik beban kerja: keluaran[grup*3+tingkat] + maksimum di indeks 9.
api.ordexa_scratch_reset();
const chartKeysPtr = api.ordexa_scratch_alloc(5 * 24);
const chartOutPtr = api.ordexa_scratch_alloc(80);
const chartKeys = new BigInt64Array(api.memory.buffer, chartKeysPtr, 5 * 3);
chartKeys.set([
  3600n, 0n, 3n,        // mendesak, berat
  48n * 3600n, 0n, 1n,  // segera, ringan
  30n * 86400n, 0n, 2n, // nanti, sedang
  3600n, 1n, 3n,        // selesai -> diabaikan
  -100n, 0n, 2n,        // terlambat (mendesak), sedang
]);
api.ordexa_chart(5, chartKeysPtr, 0n, chartOutPtr);
const chart = new BigInt64Array(api.memory.buffer, chartOutPtr, 10);
assert.equal(chart[0], 1n, 'mendesak + berat');
assert.equal(chart[1], 1n, 'mendesak + sedang (terlambat)');
assert.equal(chart[2], 0n, 'mendesak + ringan');
assert.equal(chart[5], 1n, 'segera + ringan');
assert.equal(chart[7], 1n, 'nanti + sedang');
assert.equal(chart[9], 1n, 'maksimum batang');

// Penyaringan + urutan: tugas aktif disusun menurut prioritas.
api.ordexa_scratch_reset();
const fsKeysPtr = api.ordexa_scratch_alloc(count * 32);
const fsMatchesPtr = api.ordexa_scratch_alloc(count * 4);
const fsOutPtr = api.ordexa_scratch_alloc(count * 4);
const fsKeys = new BigInt64Array(api.memory.buffer, fsKeysPtr, count * 4);
fsKeys.set([100n, 5n, 0n, 42n, -10n, 9n, 0n, 90n, 200n, 1n, 1n, 10n]);
new Uint32Array(api.memory.buffer, fsMatchesPtr, count).fill(1);
const kept = api.ordexa_filter_sort(count, fsKeysPtr, fsMatchesPtr, 4, 0, 0n, 0n, fsOutPtr);
assert.equal(kept, 2, 'dua tugas aktif diharapkan');
const order = new Uint32Array(api.memory.buffer, fsOutPtr, kept);
assert.equal(order[0], 1, 'skor tertinggi lebih dulu');
assert.equal(order[1], 0);

// Format tanggal dan label Indonesia dari inti Zig.
function bacaFormatter(panggilan) {
  const len = panggilan();
  assert.ok(len > 0, 'pemformat inti mengembalikan nol');
  return decoder.decode(new Uint8Array(api.memory.buffer, api.ordexa_format_ptr(), len));
}
assert.equal(bacaFormatter(() => api.ordexa_format_deadline(3600n, 0n, 0n)), 'Hari ini, 01.00');
assert.equal(bacaFormatter(() => api.ordexa_format_deadline(86400n + 7200n, 0n, 0n)), 'Besok, 02.00');
assert.equal(bacaFormatter(() => api.ordexa_format_deadline(-3600n, 0n, 0n)), 'Kemarin, 23.00');
assert.equal(bacaFormatter(() => api.ordexa_format_date_label(0n, 0n)), 'Kam, 1 Jan');
assert.equal(bacaFormatter(() => api.ordexa_format_relative(72n)), '3 hari lagi');
assert.equal(bacaFormatter(() => api.ordexa_format_relative(-5n)), 'terlambat 5 jam');
assert.equal(bacaFormatter(() => api.ordexa_format_input_deadline(0n, 0n, 24)), '1970-01-02T00:00');

// Perakit HTML baris tugas: pengamanan HTML dan kelas CSS dari inti Zig.
api.ordexa_scratch_reset();
const idTugas = tulisTeks('t-1');
const judulTugas = tulisTeks('Rapat <klien> & "presentasi"');
const catatanTugas = tulisTeks('Bawa <b>slide</b>');
const kategoriTugas = tulisTeks('Kerja');
const panjangBaris = api.ordexa_render_task_row(
  idTugas.ptr, idTugas.length, judulTugas.ptr, judulTugas.length,
  catatanTugas.ptr, catatanTugas.length, kategoriTugas.ptr, kategoriTugas.length,
  2, 0, 3600n, 0n, 0n, 76, 2, 2, 0,
);
assert.ok(panjangBaris > 0, 'baris tugas gagal dirakit');
const barisHtml = decoder.decode(new Uint8Array(api.memory.buffer, api.ordexa_row_ptr(), panjangBaris));
assert.ok(barisHtml.startsWith('<div class="task-row" data-id="t-1">'));
assert.ok(barisHtml.includes('&lt;klien&gt;'), 'judul harus terlindung HTML');
assert.ok(!barisHtml.includes('<klien>'), 'tag mentah tidak boleh lolos');
assert.ok(barisHtml.includes('priority-pill high'));
assert.ok(barisHtml.includes('Hari ini, 01.00'));
assert.ok(barisHtml.includes('data-action="toggle">Tandai selesai'));

// Sebaran kategori: kunci (status, id_kategori), keluaran 12 i64.
api.ordexa_scratch_reset();
const catKeysPtr = api.ordexa_scratch_alloc(5 * 16);
const catOutPtr = api.ordexa_scratch_alloc(96);
const catKeys = new BigInt64Array(api.memory.buffer, catKeysPtr, 5 * 2);
catKeys.set([0n, 0n, 1n, 0n, 0n, 1n, 0n, 99n, 1n, 2n]);
api.ordexa_category_stats(5, catKeysPtr, catOutPtr);
const kategori = new BigInt64Array(api.memory.buffer, catOutPtr, 12);
assert.equal(kategori[0], 1n, 'Belajar aktif');
assert.equal(kategori[1], 1n, 'Belajar selesai');
assert.equal(kategori[8], 1n, 'nilai kategori liar masuk Lainnya');
assert.equal(kategori[10], 3n, 'total aktif');
assert.equal(kategori[11], 2n, 'total selesai');
assert.equal(bacaString(api.ordexa_category_label_id(3)), 'Proyek');
assert.ok(api.ordexa_version_string() > 0, 'panjang versi inti positif');

// Judul notifikasi dari tabel string inti Zig.
assert.equal(bacaString(58), 'Sudah buka Ordexa hari ini?');
assert.equal(bacaString(59), 'Tenggat mendekat');

// Isi pengingat harian: varian dipilih menurut beban kerja.
assert.equal(bacaFormat(102, 0, 0), 'Belum ada tugas terjadwal. Tambahkan satu untuk hari ini?');
assert.equal(bacaFormat(103, 5, 0), 'Ada 5 tugas aktif di Ordexa. Yang mana yang dikerjakan lebih dulu?');
assert.equal(bacaFormat(104, 5, 2), 'Ada 5 tugas aktif, 2 di antaranya mendekati tenggat.');

// Pemindaian notifikasi: tugas mepet dan terlambat, terurut terdekat.
api.ordexa_scratch_reset();
const scanKeysPtr = api.ordexa_scratch_alloc(5 * 16);
const scanOutPtr = api.ordexa_scratch_alloc(5 * 4);
const scanKeys = new BigInt64Array(api.memory.buffer, scanKeysPtr, 5 * 2);
scanKeys.set([-100n, 0n, 3600n, 0n, 10n * 86400n, 0n, 3600n, 1n, 7200n, 0n]);
const terpilih = api.ordexa_notify_scan(5, scanKeysPtr, 0n, 24n, scanOutPtr);
assert.equal(terpilih, 3, 'tiga tugas layak diberi notifikasi');
const pilihan = Array.from(new Uint32Array(api.memory.buffer, scanOutPtr, terpilih));
assert.deepEqual(pilihan, [0, 1, 4], 'terurut tenggat terdekat lebih dulu');

// Isi notifikasi tugas mepet dirakit inti Zig.
api.ordexa_scratch_reset();
const judulMepet = tulisTeks('Kirim proposal klien');
const panjangDekat = api.ordexa_notify_due_body(judulMepet.ptr, judulMepet.length, 2n, 3n * 3600n, 0n, 0n);
assert.ok(panjangDekat > 0, 'isi notifikasi dekat gagal dirakit');
const isiDekat = decoder.decode(new Uint8Array(api.memory.buffer, api.ordexa_notify_ptr(), panjangDekat));
assert.ok(isiDekat.includes('\u201CKirim proposal klien\u201D mendekati tenggat'), 'judul harus berada di awal isi');
assert.ok(isiDekat.includes('tinggal 2 jam lagi'));
assert.ok(isiDekat.includes('(Hari ini, 03.00)'));
const panjangLewat = api.ordexa_notify_due_body(judulMepet.ptr, judulMepet.length, -5n, -5n * 3600n, 0n, 0n);
assert.ok(panjangLewat > 0, 'isi notifikasi lewat gagal dirakit');
const isiLewat = decoder.decode(new Uint8Array(api.memory.buffer, api.ordexa_notify_ptr(), panjangLewat));
assert.ok(isiLewat.includes('melewati tenggat'));
assert.ok(isiLewat.includes('terlambat 5 jam'));

console.log(`Smoke test WebAssembly lolos: ${file}`);
