'use strict';

// Ordexa — lapisan peramban.
// Berkas ini sengaja tipis: hanya memuat dan menyimpan tugas, menyiapkan
// masukan ke memori linear WebAssembly, merender hasil dari inti Zig,
// serta menangani event. Setiap keputusan perencanaan (skor, urutan,
// penyaringan, statistik, grafik, label, pesan UI) dihitung di src/core.zig.

const KUNCI_PENYIMPANAN = 'ordexa.tasks.v1';
const KUNCI_PENYIMPANAN_LAMA = 'ztask.tasks.v1';
const KUNCI_PENGATURAN = 'ordexa.settings.v1';
const KUNCI_NOTIF = 'ordexa.notif.v1';
const state = { tasks: [], view: 'overview', wasm: null, toastTimer: null, storageAvailable: true, analysis: null, analysisIndex: new Map() };
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const buatId = () => (crypto.randomUUID ? crypto.randomUUID() : `task-${Date.now()}-${Math.random().toString(16).slice(2)}`);

// ID pesan templat di dalam inti Zig (lihat pesan_templat di core.zig).
const M_IMPOR_OK = 100;
const M_IMPOR_KONFIRMASI = 101;
const M_NOTIF_HARIAN_KOSONG = 102;
const M_NOTIF_HARIAN_SANTAI = 103;
const M_NOTIF_HARIAN_MEPET = 104;
// ID string UI di dalam inti Zig (indeks tabel ui_strings di core.zig).
// Hanya ID yang benar-benar dipakai lapisan JS; label baris tugas, format
// tanggal, dan teks tampilan lainnya sudah dirakit penuh di dalam Zig.
const S = {
  TOAST_TAMBAH: 10, TOAST_UBAH: 11, TOAST_SELESAI: 12, TOAST_AKTIF: 13,
  TOAST_HAPUS: 14, TOAST_EKSPOR: 15, TOAST_STORAGE: 16, TOAST_WASM_GAGAL: 17,
  ENGINE_AKTIF: 18, ENGINE_MATI: 19, FORM_JUDUL_KOSONG: 21, FORM_TENGGAT: 22,
  FORM_ENGINE: 25, MODAL_BUAT: 31, MODAL_SIMPAN_UBAH: 32, MODAL_SIMPAN: 33,
  EDIT_TUGAS: 28,
  IMPOR_GAGAL: 34, KOSONG_CHART: 35, HAPUS_A: 36, HAPUS_B: 37,
  VIEW_SEMUA_JUDUL: 38, VIEW_SEMUA_SUB: 39, VIEW_HARI_INI_JUDUL: 40, VIEW_HARI_INI_SUB: 41,
  VIEW_DATANG_JUDUL: 42, VIEW_DATANG_SUB: 43, VIEW_SELESAI_JUDUL: 44, VIEW_SELESAI_SUB: 45,
  KOSONG_LIST_JUDUL: 46, KOSONG_LIST_SUB: 47, BUAT_TUGAS: 48,
  KOSONG_FOKUS_JUDUL: 49, KOSONG_FOKUS_SUB: 50, VERSI_CORE: 56,
  NOTIF_HARIAN_JUDUL: 58, NOTIF_MEPET_JUDUL: 59,
};

function escapeHtml(nilai) {
  return String(nilai ?? '').replace(/[&<>"']/g, (char) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
}

// Kategori baru memakai label Indonesia; nilai lama (versi sebelumnya)
// dipetakan sekali saat tugas dimuat dari penyimpanan.
const KATEGORI = ['Belajar', 'Kerja', 'Pribadi', 'Proyek', 'Lainnya'];
const PETA_KATEGORI_LAMA = { Study: 'Belajar', Work: 'Kerja', Personal: 'Pribadi', Project: 'Proyek', Other: 'Lainnya' };

function normalisasiTugas(task) {
  if (!task || typeof task !== 'object') return null;
  const title = String(task.title ?? '').trim();
  const deadline = String(task.deadline ?? '');
  if (!title || title.length > 120 || Number.isNaN(new Date(deadline).getTime())) return null;
  const difficulty = [1, 2, 3].includes(Number(task.difficulty)) ? Number(task.difficulty) : 2;
  const kategori_mentah = KATEGORI.includes(task.category) ? task.category : PETA_KATEGORI_LAMA[task.category];
  const category = KATEGORI.includes(kategori_mentah) ? kategori_mentah : 'Lainnya';
  return {
    id: typeof task.id === 'string' && task.id ? task.id : buatId(),
    title,
    description: String(task.description ?? '').slice(0, 1000),
    deadline,
    difficulty,
    category,
    status: task.status === 'completed' ? 'completed' : 'active',
    createdAt: Number.isFinite(Number(task.createdAt)) ? Number(task.createdAt) : Date.now(),
    updatedAt: Number.isFinite(Number(task.updatedAt)) ? Number(task.updatedAt) : Date.now(),
  };
}

function muatTugas() {
  try {
    let tersimpan = localStorage.getItem(KUNCI_PENYIMPANAN);
    // Migrasi sekali ini menjaga tugas yang dibuat pada build aplikasi sebelumnya.
    if (tersimpan === null) {
      const lama = localStorage.getItem(KUNCI_PENYIMPANAN_LAMA);
      if (lama !== null) {
        tersimpan = lama;
        localStorage.setItem(KUNCI_PENYIMPANAN, lama);
      }
    }
    const parsed = JSON.parse(tersimpan || '[]');
    const sumber = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.tasks) ? parsed.tasks : []);
    state.tasks = sumber.slice(0, 1000).map(normalisasiTugas).filter(Boolean);
  } catch (error) {
    state.tasks = [];
    console.warn('Ordexa gagal membaca data tugas setempat.', error);
  }
}

function simpanTugas() {
  try {
    localStorage.setItem(KUNCI_PENYIMPANAN, JSON.stringify(state.tasks));
    state.storageAvailable = true;
    return true;
  } catch (error) {
    state.storageAvailable = false;
    console.error('Ordexa gagal menyimpan data tugas setempat.', error);
    tampilkanToast(zigStr(S.TOAST_STORAGE) || 'Penyimpanan penuh atau tidak tersedia.', true);
    return false;
  }
}

function detikKini() { return Math.floor(Date.now() / 1000); }
function detikTenggat(tugas) { return Math.floor(new Date(tugas.deadline).getTime() / 1000); }
function offsetZonaDetik() { return -new Date().getTimezoneOffset() * 60; }
function bitStatus(tugas) { return tugas.status === 'completed' ? 1 : 0; }

// ---- Jembatan mesin Zig ---------------------------------------------------
// Setiap keputusan perencanaan (skor, penyaringan, pencarian, urutan,
// statistik, grafik, label, pesan) dihitung oleh inti WebAssembly.
// JavaScript hanya menyiapkan masukan ke memori linear dan merender hasilnya.
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function tulisGoresan(teks) {
  const bytes = encoder.encode(teks);
  const ptr = state.wasm.ordexa_scratch_alloc(bytes.length);
  if (!ptr) throw new Error('Memori goresan mesin Ordexa penuh');
  new Uint8Array(state.wasm.memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length };
}
function wasmView(TypedArray, ptr, panjang) { return new TypedArray(state.wasm.memory.buffer, ptr, panjang); }

// Baca string UI berbahasa Indonesia langsung dari tabel string inti Zig.
function zigStr(id) {
  if (!state.wasm) return '';
  const ptr = state.wasm.ordexa_string_ptr(id);
  const len = state.wasm.ordexa_string_len(id);
  if (!ptr || !len) return '';
  return decoder.decode(new Uint8Array(state.wasm.memory.buffer, ptr, len));
}
// Format pesan ber-angka (penanda {0}/{1}) di dalam inti Zig.
function zigFormat(id, a = 0, b = 0) {
  if (!state.wasm) return '';
  const len = state.wasm.ordexa_format_message(id, BigInt(a), BigInt(b));
  if (!len) return '';
  return decoder.decode(new Uint8Array(state.wasm.memory.buffer, state.wasm.ordexa_format_ptr(), len));
}

function analisaSemua() {
  state.analysisIndex = new Map();
  const n = state.tasks.length;
  if (!state.wasm || !n) { state.analysis = null; return; }
  state.wasm.ordexa_scratch_reset();
  const ptrMasuk = state.wasm.ordexa_scratch_alloc(n * 24);
  const ptrKeluar = state.wasm.ordexa_scratch_alloc(n * 40);
  if (!ptrMasuk || !ptrKeluar) { state.analysis = null; return; }
  const masukan = wasmView(BigInt64Array, ptrMasuk, n * 3);
  state.tasks.forEach((tugas, i) => {
    masukan[i * 3] = BigInt(detikTenggat(tugas));
    masukan[i * 3 + 1] = BigInt(bitStatus(tugas));
    masukan[i * 3 + 2] = BigInt(tugas.difficulty);
    state.analysisIndex.set(tugas.id, i);
  });
  state.wasm.ordexa_analyze(n, ptrMasuk, ptrKeluar, BigInt(detikKini()));
  state.analysis = Array.from(wasmView(BigInt64Array, ptrKeluar, n * 5), Number);
}
function analisaDi(tugas, bidang) {
  const indeks = state.analysisIndex.get(tugas.id);
  return (state.analysis && indeks !== undefined) ? state.analysis[indeks * 5 + bidang] : 0;
}
const sisaJam = (tugas) => analisaDi(tugas, 0);
const skorTugas = (tugas) => analisaDi(tugas, 1);
const pitaPrioritas = (tugas) => analisaDi(tugas, 2);
const emberUrgensi = (tugas) => analisaDi(tugas, 3);
const terlambat = (tugas) => analisaDi(tugas, 4) === 1;

// tampilan: 0 semua · 1 hari ini · 2 akan datang · 3 selesai · 4 aktif
// urutan: 0 prioritas · 1 tenggat · 2 dibuat
function hitungUrutan(tampilan, kunciUrut, pakaiCari) {
  const n = state.tasks.length;
  if (!state.wasm || !n) return [];
  state.wasm.ordexa_scratch_reset();
  const kini = BigInt(detikKini()), tz = BigInt(offsetZonaDetik());
  let kueri = null;
  if (pakaiCari) {
    const teks = $('#search-input').value.trim();
    if (teks) kueri = tulisGoresan(teks);
  }
  const ptrCocok = state.wasm.ordexa_scratch_alloc(n * 4);
  const ptrKunci = state.wasm.ordexa_scratch_alloc(n * 32);
  const ptrKeluar = state.wasm.ordexa_scratch_alloc(n * 4);
  if (!ptrCocok || !ptrKunci || !ptrKeluar) return [];
  const cocok = wasmView(Uint32Array, ptrCocok, n);
  const kunci = wasmView(BigInt64Array, ptrKunci, n * 4);
  for (let i = 0; i < n; i++) {
    const tugas = state.tasks[i];
    if (kueri) {
      const jerami = tulisGoresan(`${tugas.title} ${tugas.description} ${tugas.category}`);
      cocok[i] = state.wasm.ordexa_contains_lower(jerami.ptr, jerami.len, kueri.ptr, kueri.len);
    } else {
      cocok[i] = 1;
    }
    kunci[i * 4] = BigInt(detikTenggat(tugas));
    kunci[i * 4 + 1] = BigInt(tugas.createdAt);
    kunci[i * 4 + 2] = BigInt(bitStatus(tugas));
    kunci[i * 4 + 3] = BigInt(skorTugas(tugas));
  }
  const jumlah = state.wasm.ordexa_filter_sort(n, ptrKunci, ptrCocok, tampilan, kunciUrut, kini, tz, ptrKeluar);
  return Array.from(wasmView(Uint32Array, ptrKeluar, jumlah), (i) => state.tasks[i]);
}

// Label kesulitan untuk legenda grafik; label lain dirakit langsung di Zig.
function labelKesulitan(nilai) { return state.wasm ? zigStr(state.wasm.ordexa_difficulty_label_id(Number(nilai))) : '—'; }

function tampilkanToast(pesan, isError = false) {
  const toast = $('#toast'); toast.textContent = pesan; toast.classList.toggle('error', isError); toast.classList.add('show');
  clearTimeout(state.toastTimer); state.toastTimer = setTimeout(() => toast.classList.remove('show'), 2800);
}
function simpanDanRender(pesan) { const tersimpan = simpanTugas(); render(); if (pesan && tersimpan) tampilkanToast(pesan); }

async function initWasm() {
  try {
    const response = await fetch('/ordexa-core.wasm');
    if (!response.ok) throw new Error('Berkas WASM tidak tersedia');
    const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    state.wasm = instance.exports;
    document.documentElement.dataset.engine = 'zig';
    $('#engine-status').textContent = zigStr(S.ENGINE_AKTIF);
    render();
    cekNotifikasi();
  } catch (error) {
    console.warn('Inti Zig WebAssembly gagal dimuat; memakai antarmuka aman.', error);
    document.documentElement.dataset.engine = 'unavailable';
    $('#engine-status').textContent = zigStr(S.ENGINE_MATI) || 'Inti Zig tidak tersedia';
    tampilkanToast(zigStr(S.TOAST_WASM_GAGAL) || 'Inti Zig gagal dimuat. Muat ulang halaman.', true);
  }
}

function renderStatistik() {
  const n = state.tasks.length;
  let total = n, selesai = 0, aktif = n, telat = 0, persen = 0;
  if (state.wasm && n) {
    state.wasm.ordexa_scratch_reset();
    const ptrKunci = state.wasm.ordexa_scratch_alloc(n * 16);
    const ptrKeluar = state.wasm.ordexa_scratch_alloc(40);
    if (ptrKunci && ptrKeluar) {
      const kunci = wasmView(BigInt64Array, ptrKunci, n * 2);
      state.tasks.forEach((tugas, i) => { kunci[i * 2] = BigInt(detikTenggat(tugas)); kunci[i * 2 + 1] = BigInt(bitStatus(tugas)); });
      state.wasm.ordexa_stats(n, ptrKunci, BigInt(detikKini()), ptrKeluar);
      [total, selesai, aktif, telat, persen] = Array.from(wasmView(BigInt64Array, ptrKeluar, 5), Number);
    }
  }
  $('#stat-total').textContent = total;
  $('#stat-active').textContent = aktif;
  $('#stat-completed').textContent = selesai;
  $('#stat-overdue').textContent = telat;
  $('#nav-all-count').textContent = total;
  $('#progress-percent').textContent = `${persen}%`;
  // Warna arc mengikuti token sistem desain (var() berlaku di style inline).
  $('#progress-ring').style.background = `conic-gradient(var(--teal) ${persen * 3.6}deg, var(--stone-soft) ${persen * 3.6}deg 360deg)`;
  $('#progress-done-count').textContent = selesai;
  $('#progress-open-count').textContent = aktif;
}

// Grafik beban kerja: pengelompokan urgensi x kesulitan dihitung inti Zig.
function renderGrafik() {
  const chart = $('#priority-chart');
  const n = state.tasks.length;
  const aktif = state.tasks.filter((tugas) => tugas.status !== 'completed').length;
  let keluar = null, maks = 1;
  if (state.wasm && n) {
    state.wasm.ordexa_scratch_reset();
    const ptrKunci = state.wasm.ordexa_scratch_alloc(n * 24);
    const ptrKeluar = state.wasm.ordexa_scratch_alloc(80);
    if (ptrKunci && ptrKeluar) {
      const kunci = wasmView(BigInt64Array, ptrKunci, n * 3);
      state.tasks.forEach((tugas, i) => {
        kunci[i * 3] = BigInt(detikTenggat(tugas));
        kunci[i * 3 + 1] = BigInt(bitStatus(tugas));
        kunci[i * 3 + 2] = BigInt(tugas.difficulty);
      });
      state.wasm.ordexa_chart(n, ptrKunci, BigInt(detikKini()), ptrKeluar);
      keluar = Array.from(wasmView(BigInt64Array, ptrKeluar, 10), Number);
      maks = Math.max(1, keluar[9]);
    }
  }
  if (!keluar || !aktif) { chart.innerHTML = `<div class="chart-empty">${escapeHtml(zigStr(S.KOSONG_CHART) || 'Belum ada tugas aktif untuk ditampilkan.')}</div>`; return; }
  // keluar[grup*3+tingkat]: grup 0 mendesak, 1 segera, 2 nanti; tingkat 0 berat, 1 sedang, 2 ringan.
  const labelTingkat = [labelKesulitan(3), labelKesulitan(2), labelKesulitan(1)];
  chart.innerHTML = [0, 1, 2].map((grup) => {
    const jumlah = [0, 1, 2].map((k) => keluar[grup * 3 + k]);
    return `<div class="chart-group">${jumlah.map((banyak, i) => `<div class="chart-bar ${['bar-heavy','bar-medium','bar-light'][i]}" style="height:${banyak ? Math.max(5,(banyak/maks)*100) : 2}%" data-count="${banyak}" title="${escapeHtml(labelTingkat[i])}: ${banyak}"></div>`).join('')}</div>`;
  }).join('');
}

// Sebaran kategori: agregasi aktif/selesai per kategori dihitung inti Zig.
function renderKategori() {
  const wadah = $('#category-list');
  const n = state.tasks.length;
  const kosong = `<div class="chart-empty">${escapeHtml(zigStr(S.KOSONG_CHART) || 'Belum ada tugas aktif untuk ditampilkan.')}</div>`;
  if (!state.wasm || !n) { wadah.innerHTML = kosong; return; }
  state.wasm.ordexa_scratch_reset();
  const ptrKunci = state.wasm.ordexa_scratch_alloc(n * 16);
  const ptrKeluar = state.wasm.ordexa_scratch_alloc(96);
  if (!ptrKunci || !ptrKeluar) { wadah.innerHTML = kosong; return; }
  const kunci = wasmView(BigInt64Array, ptrKunci, n * 2);
  state.tasks.forEach((tugas, i) => {
    kunci[i * 2] = BigInt(bitStatus(tugas));
    kunci[i * 2 + 1] = BigInt(Math.max(0, KATEGORI.indexOf(tugas.category)));
  });
  state.wasm.ordexa_category_stats(n, ptrKunci, ptrKeluar);
  const keluar = Array.from(wasmView(BigInt64Array, ptrKeluar, 12), Number);
  const totalAktif = keluar[10] || 1;
  const baris = [0, 1, 2, 3, 4].map((k) => {
    const aktif = keluar[k * 2], selesai = keluar[k * 2 + 1];
    if (!aktif && !selesai) return '';
    const persen = Math.round((aktif / totalAktif) * 100);
    const label = zigStr(state.wasm.ordexa_category_label_id(k));
    return `<div class="category-row" title="${aktif} aktif, ${selesai} selesai"><span class="category-name">${escapeHtml(label)}</span><div class="category-bar"><i style="width:${persen}%"></i></div><span class="category-count">${aktif}</span></div>`;
  }).join('');
  wadah.innerHTML = baris || kosong;
}

// Rakit HTML satu baris lewat inti Zig: pengamanan HTML, kelas CSS, label,
// dan format tanggal semuanya dihitung di src/core.zig. Lapisan JS hanya
// menulis string mentah ke arena goresan lalu membaca hasil HTML jadi.
function barisTugas(tugas) {
  if (!state.wasm) return '';
  state.wasm.ordexa_scratch_reset();
  const id = tulisGoresan(tugas.id);
  const judul = tulisGoresan(tugas.title);
  const catatan = tulisGoresan(tugas.description || '');
  const kategori = tulisGoresan(tugas.category);
  const detikTenggatNilai = Number.isNaN(new Date(tugas.deadline).getTime()) ? 0 : detikTenggat(tugas);
  const panjang = Number(state.wasm.ordexa_render_task_row(
    id.ptr, id.len, judul.ptr, judul.len, catatan.ptr, catatan.len, kategori.ptr, kategori.len,
    Number(tugas.difficulty), bitStatus(tugas),
    BigInt(detikTenggatNilai), BigInt(detikKini()), BigInt(offsetZonaDetik()),
    // Param i64 dikirim BigInt; param u32 cukup Number.
    skorTugas(tugas), pitaPrioritas(tugas), emberUrgensi(tugas), terlambat(tugas) ? 1 : 0,
  ));
  if (!panjang) return '';
  return decoder.decode(new Uint8Array(state.wasm.memory.buffer, state.wasm.ordexa_row_ptr(), panjang));
}
function renderWadahTugas(elemen, daftar, judulKosong, deskripsiKosong) {
  if (!daftar.length) {
    elemen.innerHTML = `<div class="empty-state"><strong>${escapeHtml(judulKosong)}</strong><p>${escapeHtml(deskripsiKosong)}</p><button class="secondary-button" data-action="create" type="button">${escapeHtml(zigStr(S.BUAT_TUGAS) || 'Tambah tugas')}</button></div>`;
    return;
  }
  elemen.innerHTML = daftar.map(barisTugas).join('');
}
function renderTugasFokus() {
  const fokus = hitungUrutan(4, 0, false).slice(0, 5);
  renderWadahTugas($('#focus-task-list'), fokus, zigStr(S.KOSONG_FOKUS_JUDUL) || 'Belum ada tugas.', zigStr(S.KOSONG_FOKUS_SUB) || 'Tambahkan tugas untuk mulai memantau prioritas.');
}
const ID_TAMPILAN = { all: 0, today: 1, upcoming: 2, completed: 3 };
const ID_URUTAN = { priority: 0, deadline: 1, created: 2 };
function tugasTersaring() {
  return hitungUrutan(ID_TAMPILAN[state.view] ?? 0, ID_URUTAN[$('#sort-select').value] ?? 0, true);
}
const JUDUL_TAMPILAN = {
  all: [S.VIEW_SEMUA_JUDUL, S.VIEW_SEMUA_SUB],
  today: [S.VIEW_HARI_INI_JUDUL, S.VIEW_HARI_INI_SUB],
  upcoming: [S.VIEW_DATANG_JUDUL, S.VIEW_DATANG_SUB],
  completed: [S.VIEW_SELESAI_JUDUL, S.VIEW_SELESAI_SUB],
};
function renderTampilanDaftar() {
  const [idJudul, idSubjudul] = JUDUL_TAMPILAN[state.view] || JUDUL_TAMPILAN.all;
  $('#list-title').textContent = zigStr(idJudul) || 'Semua tugas';
  $('#list-subtitle').textContent = zigStr(idSubjudul) || '';
  renderWadahTugas($('#all-task-list'), tugasTersaring(), zigStr(S.KOSONG_LIST_JUDUL) || 'Tidak ada tugas yang cocok.', zigStr(S.KOSONG_LIST_SUB) || 'Ubah kata kunci pencarian atau tambahkan tugas baru.');
}
function render() {
  analisaSemua();
  renderStatistik(); renderGrafik(); renderKategori(); renderTugasFokus(); renderTampilanDaftar(); perbaruiPengaturan();
  // Label tanggal bilah atas diformat inti Zig, mis. "Jum, 21 Nov".
  const panjangLabel = state.wasm ? Number(state.wasm.ordexa_format_date_label(BigInt(detikKini()), BigInt(offsetZonaDetik()))) : 0;
  $('#top-date').textContent = panjangLabel ? decoder.decode(new Uint8Array(state.wasm.memory.buffer, state.wasm.ordexa_format_ptr(), panjangLabel)) : '';
}
// Pemetaan tampilan -> bagian halaman; tampilan daftar berbagi satu bagian.
const BAGIAN_TAMPILAN = { overview: '#overview-view', all: '#list-view', today: '#list-view', upcoming: '#list-view', completed: '#list-view', settings: '#settings-view' };
const NAMA_BAGIAN = { overview: 'Dashboard', all: 'Semua tugas', today: 'Hari ini', upcoming: 'Akan datang', completed: 'Selesai', settings: 'Pengaturan' };
function aturTampilan(view) {
  state.view = view;
  const bagian = BAGIAN_TAMPILAN[view] || '#overview-view';
  $('#overview-view').classList.toggle('hidden', bagian !== '#overview-view');
  $('#list-view').classList.toggle('hidden', bagian !== '#list-view');
  $('#settings-view').classList.toggle('hidden', bagian !== '#settings-view');
  $('#breadcrumb-current').textContent = NAMA_BAGIAN[view] || 'Dashboard';
  $$('.nav-item').forEach((button) => button.classList.toggle('active', button.dataset.view === view));
  $('#sidebar').classList.remove('open');
  if (bagian === '#list-view') renderTampilanDaftar();
  if (bagian === '#settings-view') perbaruiPengaturan();
  perbaruiIndikatorBawah();
}

// Indikator cair navigasi bawah — Liquid Glass. Posisi dan lebar selalu dihitung
// dari offsetLeft/offsetWidth item aktif yang sebenarnya (bukan asumsi kolom
// seragam), lalu pil kaca dianimasikan dengan Web Animations API memakai dua
// tepi independen: tepi depan (arah tujuan) melaju lebih dulu, tepi belakang
// tertarik elastis menyusul — pil meregang saat mengalir lalu menyusut halus
// saat mendarat. Intensitas peregangan dan durasi diskalakan berdasarkan jarak
// perpindahan. Semua gerakan hanya transform (translateX + scaleX) sehingga
// tata letak ikon/label tidak pernah bergeser.
let animIndikatorBawah = null;

// Baca keadaan visual indikator (tepi kiri & lebar tampak) termasuk saat
// animasi masih berjalan — dipakai agar ketukan beruntun yang cepat tetap
// berlanjut mulus dari posisi visual saat ini tanpa lompatan.
function keadaanIndikator(indikator) {
  const gaya = getComputedStyle(indikator);
  const lebarSusun = parseFloat(gaya.width) || indikator.offsetWidth || 1;
  let kiri = parseFloat(indikator.dataset.kiri || '0') || 0;
  let skala = 1;
  if (gaya.transform && gaya.transform !== 'none') {
    try {
      const m = new DOMMatrixReadOnly(gaya.transform);
      kiri = m.m41;
      skala = m.a || 1;
    } catch { /* pertahankan nilai terakhir yang diketahui */ }
  }
  return { kiri, lebar: lebarSusun * skala };
}

// Rancang dan jalankan animasi cair dari keadaan visual saat ini ke item tujuan.
// Lebar layout langsung diset ke lebar tujuan; keyframe pertama mengompensasi
// dengan scaleX sehingga tidak ada lompatan walau lebar item berbeda.
function luncurkanIndikatorCair(indikator, dari, ke) {
  const w2 = Math.max(ke.lebar, 1);
  const L0 = dari.kiri;
  const W0 = Math.max(dari.lebar, 1);
  const R0 = L0 + W0;
  const L2 = ke.kiri;
  const R2 = L2 + w2;
  const d = L2 - L0;
  const jarak = Math.abs(d);
  indikator.style.width = `${w2}px`;
  const tetapkanAkhir = () => {
    indikator.style.transform = `translateX(${L2}px)`;
    indikator.style.width = `${w2}px`;
    indikator.dataset.kiri = String(L2);
    indikator.style.setProperty('--kilau', '50%');
  };
  if (jarak < 1) { tetapkanAkhir(); return null; }
  // Jarak memengaruhi karakter gerak: tetangga lembut & cepat, jauh lebih
  // meregang dan sedikit lebih lama (tanpa bounce berlebihan).
  const regang = Math.min(0.1 + jarak / 650, 0.38);
  const durasi = Math.round(290 + Math.min(jarak, 320) * 0.38);
  const C0 = (L0 + R0) / 2;
  const C2 = (L2 + R2) / 2;
  // Puncak peregangan di tengah perjalanan: pil melebar elastis searah gerak.
  const Wp = ((W0 + w2) / 2) * (1 + regang);
  const Cp = C0 + d * 0.5;
  const Lp = Cp - Wp / 2;
  const Rp = Cp + Wp / 2;
  // Pendaratan: sedikit menyusut dan undershoot kecil sebelum menetap halus.
  const Ws = w2 * (1 - regang * 0.22);
  const Cs = C2 - d * 0.05;
  const Ls = Cs - Ws / 2;
  const Rs = Cs + Ws / 2;
  const bingkai = (kiri, kanan, offset, easing) => {
    const kf = { transform: `translateX(${kiri.toFixed(2)}px) scaleX(${((kanan - kiri) / w2).toFixed(4)})` };
    if (offset !== null && offset !== undefined) kf.offset = offset;
    if (easing) kf.easing = easing;
    return kf;
  };
  const anim = indikator.animate([
    bingkai(L0, R0, 0, 'cubic-bezier(0.45, 0, 0.5, 1)'),
    bingkai(Lp, Rp, 0.42, 'cubic-bezier(0.3, 0.6, 0.25, 1)'),
    bingkai(Ls, Rs, 0.78, 'cubic-bezier(0.3, 0.2, 0.2, 1)'),
    bingkai(L2, R2, 1),
  ], { duration: durasi, fill: 'forwards' });
  // Pantulan cahaya mengalir berlawanan arah gerak lalu kembali ke pusat,
  // memberi kesan cahaya menembus kaca yang bergerak.
  indikator.style.setProperty('--kilau-dur', `${durasi}ms`);
  indikator.style.setProperty('--kilau', d >= 0 ? '28%' : '72%');
  anim.onfinish = () => {
    tetapkanAkhir();
    anim.cancel();
    if (animIndikatorBawah === anim) animIndikatorBawah = null;
  };
  return anim;
}

function perbaruiIndikatorBawah(opsi) {
  const nav = $('#bottom-nav');
  const aktif = nav.querySelector('.bn-item.active');
  const indikator = nav.querySelector('.bn-indicator');
  if (!aktif || !indikator) return;
  const lompat = !indikator.dataset.siap
    || window.matchMedia('(prefers-reduced-motion: reduce)').matches
    || !!(opsi && opsi.lompat);
  // Baca keadaan visual SEBELUM animasi lama dibatalkan agar ketukan cepat
  // beruntun selalu bersambung dari posisi visual terkini.
  const kini = lompat ? null : keadaanIndikator(indikator);
  if (animIndikatorBawah) { animIndikatorBawah.cancel(); animIndikatorBawah = null; }
  if (lompat) {
    indikator.style.width = `${aktif.offsetWidth}px`;
    indikator.style.transform = `translateX(${aktif.offsetLeft}px)`;
    indikator.dataset.kiri = String(aktif.offsetLeft);
    indikator.style.setProperty('--kilau', '50%');
    indikator.dataset.siap = '1';
    return;
  }
  animIndikatorBawah = luncurkanIndikatorCair(indikator, kini, { kiri: aktif.offsetLeft, lebar: aktif.offsetWidth });
}
// Segarkan panel pengaturan: status inti Zig, versi, dan jumlah tugas tersimpan.
function perbaruiPengaturan() {
  const mesin = $('#settings-engine');
  if (mesin) mesin.textContent = state.wasm ? zigStr(S.ENGINE_AKTIF) : (zigStr(S.ENGINE_MATI) || 'Inti Zig tidak tersedia');
  const versi = $('#settings-core-version');
  if (versi) versi.textContent = state.wasm ? (zigStr(S.VERSI_CORE) || '—') : '—';
  const jumlah = $('#settings-task-count');
  if (jumlah) jumlah.textContent = state.tasks.length;
}
// ---- Notifikasi: pengingat harian dan peringatan tugas mepet ---------------
// Ordexa tidak punya server, jadi pengingat dijadwalkan di peramban: selama
// halaman terbuka (atau PWA terpasang), penjadwal memeriksa tiap 30 detik.
// Dua keputusan penting tetap di inti Zig: tugas mana yang layak diberi
// notifikasi (ordexa_notify_scan) dan bagaimana bunyi pesannya (templat dan
// perakit isi notifikasi di src/core.zig).

const PENGATURAN_BAWAAN = { harian: false, jamHarian: '09:00', mepet: false, ambangMepet: 24 };
const pengaturan = { ...PENGATURAN_BAWAAN };
const notifState = { harian: '', mepet: {} };
const dukungNotifikasi = typeof Notification !== 'undefined';

function muatPengaturan() {
  try { Object.assign(pengaturan, PENGATURAN_BAWAAN, JSON.parse(localStorage.getItem(KUNCI_PENGATURAN) || '{}')); } catch { /* pakai bawaan */ }
  try { Object.assign(notifState, { harian: '', mepet: {} }, JSON.parse(localStorage.getItem(KUNCI_NOTIF) || '{}')); } catch { /* pakai bawaan */ }
  // Pastikan ambang selalu angka (penyimpanan lama bisa memuat string).
  pengaturan.ambangMepet = Number(pengaturan.ambangMepet) || 24;
}
function simpanPengaturan() { try { localStorage.setItem(KUNCI_PENGATURAN, JSON.stringify(pengaturan)); } catch { /* abaikan */ } }
function simpanNotifState() { try { localStorage.setItem(KUNCI_NOTIF, JSON.stringify(notifState)); } catch { /* abaikan */ } }

function terapkanPengaturanUI() {
  $('#notif-daily-toggle').checked = !!pengaturan.harian;
  $('#notif-daily-time').value = pengaturan.jamHarian || '09:00';
  $('#notif-due-toggle').checked = !!pengaturan.mepet;
  $('#notif-due-threshold').value = String(pengaturan.ambangMepet || 24);
  perbaruiIzinUI();
}

function perbaruiIzinUI() {
  const teks = $('#notif-permission-text');
  const tombol = $('#notif-permission-button');
  if (!teks || !tombol) return;
  const label = {
    granted: 'Izin sudah diberikan. Notifikasi Ordexa siap berjalan.',
    denied: 'Izin ditolak. Aktifkan notifikasi dari pengaturan situs di peramban, lalu muat ulang halaman.',
    default: 'Izin belum diminta. Aktifkan salah satu pengingat di atas, atau tekan tombol ini.',
    unsupported: 'Peramban ini belum mendukung Notification API.',
  };
  const status = dukungNotifikasi ? Notification.permission : 'unsupported';
  teks.textContent = label[status] || label.default;
  tombol.classList.toggle('hidden', status !== 'default');
}

async function mintaIzinNotifikasi() {
  if (!dukungNotifikasi || Notification.permission === 'granted') return dukungNotifikasi && Notification.permission === 'granted';
  if (Notification.permission === 'denied') return false;
  try { return (await Notification.requestPermission()) === 'granted'; } catch { return false; }
}

// Tampilkan notifikasi lewat service worker bila tersedia (lebih andal untuk
// PWA terpasang), jatuh ke Notification biasa bila tidak.
function tampilkanNotifikasi(judul, isi, tag) {
  if (!dukungNotifikasi || Notification.permission !== 'granted') return;
  const opsi = { body: isi, tag, icon: '/icons/icon-192.png', badge: '/icons/icon-192.png' };
  if (navigator.serviceWorker) {
    navigator.serviceWorker.ready
      .then((registrasi) => registrasi.showNotification(judul, opsi))
      .catch(() => { try { new Notification(judul, opsi); } catch { /* abaikan */ } });
  } else {
    try { new Notification(judul, opsi); } catch { /* abaikan */ }
  }
}

const tanggalHarian = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};
const detikHarianKini = () => { const d = new Date(); return d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds(); };

// Pengingat harian: "Sudah buka Ordexa hari ini?" — sekali per hari, setelah
// jam yang dipilih pengguna. Isinya dipilih inti Zig menurut beban kerja.
function cekNotifikasiHarian() {
  if (!pengaturan.harian) return;
  const hariIni = tanggalHarian();
  if (notifState.harian === hariIni) return;
  const [jam, menit] = String(pengaturan.jamHarian || '09:00').split(':').map(Number);
  if (detikHarianKini() < (jam || 0) * 3600 + (menit || 0) * 60) return;

  analisaSemua();
  let aktif = 0, mepet = 0;
  state.tasks.forEach((tugas) => {
    if (tugas.status === 'completed') return;
    aktif += 1;
    if (emberUrgensi(tugas) >= 2) mepet += 1;
  });
  const idPesan = aktif === 0 ? M_NOTIF_HARIAN_KOSONG : (mepet > 0 ? M_NOTIF_HARIAN_MEPET : M_NOTIF_HARIAN_SANTAI);
  tampilkanNotifikasi(zigStr(S.NOTIF_HARIAN_JUDUL) || 'Sudah buka Ordexa hari ini?', zigFormat(idPesan, aktif, mepet), 'ordexa-harian');
  notifState.harian = hariIni;
  simpanNotifState();
}

// Peringatan tugas mepet: inti Zig memindai tugas yang sisa waktunya sudah
// menyentuh ambang (atau terlanjur lewat); tiap tugas hanya dinotifikasi satu
// kali per nilai tenggatnya supaya tidak berisik.
function cekNotifikasiMepet() {
  if (!pengaturan.mepet || !state.wasm) return;
  const n = state.tasks.length;
  if (!n) return;
  state.wasm.ordexa_scratch_reset();
  const ptrKunci = state.wasm.ordexa_scratch_alloc(n * 16);
  const ptrKeluar = state.wasm.ordexa_scratch_alloc(n * 4);
  if (!ptrKunci || !ptrKeluar) return;
  const kunci = wasmView(BigInt64Array, ptrKunci, n * 2);
  state.tasks.forEach((tugas, i) => {
    kunci[i * 2] = BigInt(detikTenggat(tugas));
    kunci[i * 2 + 1] = BigInt(bitStatus(tugas));
  });
  const jumlah = Number(state.wasm.ordexa_notify_scan(n, ptrKunci, BigInt(detikKini()), BigInt(pengaturan.ambangMepet), ptrKeluar));
  const indeksTugas = Array.from(wasmView(Uint32Array, ptrKeluar, jumlah));

  // Bersihkan catatan notifikasi untuk tugas yang sudah tidak ada.
  const kunciValid = new Set(state.tasks.map((tugas) => `${tugas.id}:${tugas.deadline}`));
  Object.keys(notifState.mepet).forEach((kunciLama) => { if (!kunciValid.has(kunciLama)) delete notifState.mepet[kunciLama]; });

  indeksTugas.forEach((indeks) => {
    const tugas = state.tasks[indeks];
    if (!tugas || tugas.status === 'completed') return;
    const kunciTugas = `${tugas.id}:${tugas.deadline}`;
    if (notifState.mepet[kunciTugas]) return;
    // Rakit isi pesan di inti Zig: judul + sisa waktu + label tenggat.
    state.wasm.ordexa_scratch_reset();
    const judul = tulisGoresan(tugas.title);
    const panjang = Number(state.wasm.ordexa_notify_due_body(
      judul.ptr, judul.len,
      BigInt(state.wasm.ordexa_hours_left(BigInt(detikTenggat(tugas)), BigInt(detikKini()))),
      BigInt(detikTenggat(tugas)), BigInt(detikKini()), BigInt(offsetZonaDetik()),
    ));
    const isi = panjang ? decoder.decode(new Uint8Array(state.wasm.memory.buffer, state.wasm.ordexa_notify_ptr(), panjang)) : tugas.title;
    tampilkanNotifikasi(zigStr(S.NOTIF_MEPET_JUDUL) || 'Tenggat mepet', isi, `ordexa-mepet-${tugas.id}`);
    notifState.mepet[kunciTugas] = 1;
  });
  simpanNotifState();
}

function cekNotifikasi() {
  try { cekNotifikasiHarian(); cekNotifikasiMepet(); } catch (error) { console.warn('Pemeriksaan notifikasi Ordexa gagal.', error); }
}

// Nilai bawaan bidang tenggat (besok pukul 00.00 setempat) diformat inti Zig
// dalam bentuk yang siap dipakai input datetime-local.
function nilaiBawaanTenggat() {
  if (state.wasm) {
    const panjang = Number(state.wasm.ordexa_format_input_deadline(BigInt(detikKini()), BigInt(offsetZonaDetik()), 24));
    if (panjang) return decoder.decode(new Uint8Array(state.wasm.memory.buffer, state.wasm.ordexa_format_ptr(), panjang));
  }
  const bawaan = new Date(Date.now() + 24 * 60 * 60 * 1000); bawaan.setMinutes(0, 0, 0);
  return `${bawaan.getFullYear()}-${String(bawaan.getMonth() + 1).padStart(2, '0')}-${String(bawaan.getDate()).padStart(2, '0')}T${String(bawaan.getHours()).padStart(2, '0')}:00`;
}
function bukaModal(tugas=null) {
  $('#task-form').reset(); $('#form-error').textContent='';
  $('#task-id').value=tugas?.id||'';
  $('#modal-title').textContent=tugas?zigStr(S.EDIT_TUGAS):zigStr(S.MODAL_BUAT);
  $('#save-task-button').textContent=tugas?zigStr(S.MODAL_SIMPAN_UBAH):zigStr(S.MODAL_SIMPAN);
  $('#task-title').value=tugas?.title||'';
  $('#task-description').value=tugas?.description||'';
  $('#task-deadline').value=tugas?.deadline||nilaiBawaanTenggat();
  $('#task-difficulty').value=String(tugas?.difficulty||2);
  $('#task-category').value=tugas?.category||'Belajar';
  $('#task-status').value=tugas?.status||'active';
  $('#task-modal').classList.remove('hidden'); $('#task-title').focus();
}
function tutupModal() { $('#task-modal').classList.add('hidden'); }
function kirimForm(event) {
  event.preventDefault();
  const judul=$('#task-title').value.trim(), tenggat=$('#task-deadline').value;
  if (!state.wasm) { $('#form-error').textContent='Inti Zig belum siap. Muat ulang halaman lalu coba lagi.'; return; }
  if (!judul || !tenggat || Number.isNaN(new Date(tenggat).getTime())) {
    // Validasi cepat di sisi form; kode pesan tetap merujuk tabel string Zig.
    $('#form-error').textContent = judul ? zigStr(S.FORM_TENGGAT) : zigStr(S.FORM_JUDUL_KOSONG);
    return;
  }
  // Validasi penuh oleh inti Zig: mengembalikan ID pesan kesalahan (0 = valid).
  const byteJudul = encoder.encode(judul).length;
  const detikTenggatNilai = Math.floor(new Date(tenggat).getTime()/1000);
  const idPesan = Number(state.wasm.ordexa_validate_ex(byteJudul, BigInt(detikTenggatNilai)));
  if (idPesan) { $('#form-error').textContent = zigStr(idPesan); return; }
  const id=$('#task-id').value;
  const ada=state.tasks.find((item)=>item.id===id);
  const tugas={id:id||buatId(),title:judul,description:$('#task-description').value.trim(),deadline:tenggat,difficulty:Number($('#task-difficulty').value),category:$('#task-category').value,status:$('#task-status').value,createdAt:ada?.createdAt||Date.now(),updatedAt:Date.now()};
  if (ada) state.tasks=state.tasks.map((item)=>item.id===id?tugas:item); else state.tasks.push(tugas);
  tutupModal(); simpanDanRender(ada?zigStr(S.TOAST_UBAH):zigStr(S.TOAST_TAMBAH));
}
function aksiTugas(event) {
  const tombol=event.target.closest('[data-action]'); if(!tombol)return;
  const aksi=tombol.dataset.action;
  if (aksi === 'create') { bukaModal(); return; }
  const baris=tombol.closest('.task-row'); if(!baris)return;
  const tugas=state.tasks.find((item)=>item.id===baris.dataset.id); if(!tugas)return;
  if(aksi==='menu') { const menu=baris.querySelector('.row-menu'); $$('.row-menu').forEach((item)=>{if(item!==menu)item.classList.add('hidden')}); menu.classList.toggle('hidden'); return; }
  if(aksi==='edit') { bukaModal(tugas); }
  if(aksi==='toggle') { tugas.status=tugas.status==='completed'?'active':'completed'; tugas.updatedAt=Date.now(); simpanDanRender(tugas.status==='completed'?zigStr(S.TOAST_SELESAI):zigStr(S.TOAST_AKTIF)); }
  if(aksi==='delete') { if(confirm(zigStr(S.HAPUS_A)+tugas.title+zigStr(S.HAPUS_B))){state.tasks=state.tasks.filter((item)=>item.id!==tugas.id);simpanDanRender(zigStr(S.TOAST_HAPUS));} }
}

function eksporTugas() {
  const cadangan = { app: 'Ordexa', version: 1, exportedAt: new Date().toISOString(), tasks: state.tasks };
  const blob = new Blob([JSON.stringify(cadangan, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const tautan = document.createElement('a');
  tautan.href = url;
  tautan.download = `ordexa-cadangan-${new Date().toISOString().slice(0, 10)}.json`;
  document.body.appendChild(tautan); tautan.click(); tautan.remove(); URL.revokeObjectURL(url);
  tampilkanToast(zigStr(S.TOAST_EKSPOR));
}
async function imporTugas(berkas) {
  if (!berkas) return;
  try {
    const parsed = JSON.parse(await berkas.text());
    const masuk = Array.isArray(parsed) ? parsed : parsed?.tasks;
    if (!Array.isArray(masuk)) throw new Error('Format cadangan tidak valid');
    const bersih = masuk.slice(0, 1000).map(normalisasiTugas).filter(Boolean);
    if (!bersih.length && masuk.length) throw new Error('Tidak ada tugas valid dalam cadangan ini');
    if (!confirm(zigFormat(M_IMPOR_KONFIRMASI, bersih.length, state.tasks.length))) return;
    state.tasks = bersih;
    simpanDanRender(zigFormat(M_IMPOR_OK, bersih.length));
  } catch (error) {
    console.error('Impor gagal.', error);
    tampilkanToast(zigStr(S.IMPOR_GAGAL), true);
  } finally {
    $('#import-tasks-file').value = '';
  }
}

$('#task-form').addEventListener('submit',kirimForm);
$('#export-tasks').addEventListener('click',eksporTugas);
$('#import-tasks-button').addEventListener('click',()=>$('#import-tasks-file').click());
$('#import-tasks-file').addEventListener('change',(event)=>imporTugas(event.target.files?.[0]));
$('#add-task-top').addEventListener('click',()=>bukaModal());
$('#add-task-list').addEventListener('click',()=>bukaModal());
$('#add-task-bottom').addEventListener('click',()=>bukaModal());
$('#close-modal').addEventListener('click',tutupModal);
$('#cancel-modal').addEventListener('click',tutupModal);
$('#task-modal').addEventListener('click',(event)=>{if(event.target===$('#task-modal'))tutupModal()});
$('#focus-task-list').addEventListener('click',aksiTugas);
$('#all-task-list').addEventListener('click',aksiTugas);
$('#search-input').addEventListener('input',renderTampilanDaftar);
$('#sort-select').addEventListener('change',renderTampilanDaftar);
$$('[data-view]').forEach((button)=>button.addEventListener('click',()=>aturTampilan(button.dataset.view)));
$('#mobile-menu').addEventListener('click',()=>$('#sidebar').classList.toggle('open'));

// Pengikatan panel notifikasi: menyalakan saklar otomatis meminta izin
// (harus berasal dari gestur pengguna agar tidak diblokir peramban).
$('#notif-daily-toggle').addEventListener('change', async (event) => {
  if (event.target.checked && !(await mintaIzinNotifikasi())) {
    event.target.checked = false;
    tampilkanToast('Izin notifikasi belum diberikan peramban.', true);
    perbaruiIzinUI();
    return;
  }
  pengaturan.harian = event.target.checked; simpanPengaturan(); perbaruiIzinUI(); cekNotifikasi();
});
$('#notif-daily-time').addEventListener('change', (event) => { pengaturan.jamHarian = event.target.value || '09:00'; simpanPengaturan(); });
$('#notif-due-toggle').addEventListener('change', async (event) => {
  if (event.target.checked && !(await mintaIzinNotifikasi())) {
    event.target.checked = false;
    tampilkanToast('Izin notifikasi belum diberikan peramban.', true);
    perbaruiIzinUI();
    return;
  }
  pengaturan.mepet = event.target.checked; simpanPengaturan(); perbaruiIzinUI(); cekNotifikasi();
});
$('#notif-due-threshold').addEventListener('change', (event) => { pengaturan.ambangMepet = Number(event.target.value) || 24; simpanPengaturan(); });
$('#notif-permission-button').addEventListener('click', async () => { await mintaIzinNotifikasi(); perbaruiIzinUI(); });
document.addEventListener('click',(event)=>{if(!event.target.closest('.row-actions'))$$('.row-menu').forEach((menu)=>menu.classList.add('hidden'))});
document.addEventListener('click',(event)=>{const sidebar=$('#sidebar');if(sidebar.classList.contains('open')&&!event.target.closest('#sidebar')&&!event.target.closest('#mobile-menu'))sidebar.classList.remove('open')});
document.addEventListener('keydown',(event)=>{if(event.key==='Escape')tutupModal();if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){event.preventDefault();if(state.view==='overview'||state.view==='settings')aturTampilan('all');$('#search-input').focus()}});

muatTugas(); muatPengaturan(); terapkanPengaturanUI(); render(); initWasm();

// Indikator navigasi bawah perlu ukuran final: tunggu font Manrope selesai
// dimuat, lalu ukur; ikut perbarui saat jendela diubah ukurannya.
perbaruiIndikatorBawah();
if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => perbaruiIndikatorBawah()).catch(() => {});
// Saat ukuran layar / orientasi berubah, indikator diposisikan ulang tanpa
// animasi supaya selalu tepat di bawah item aktif seketika.
window.addEventListener('resize', () => perbaruiIndikatorBawah({ lompat: true }), { passive: true });

// Pintasan aplikasi (app shortcut) dari manifest PWA mendarat sebagai query
// pada start_url, mis. "/?aksi=tugas-baru" atau "/?tampilan=today".
// Setelah diterapkan, bersihkan query agar tautan berbagi/segarkan ulang
// kembali normal.
(() => {
  try {
    const params = new URLSearchParams(window.location.search);
    const tampilan = params.get('tampilan');
    const aksi = params.get('aksi');
    if (tampilan && BAGIAN_TAMPILAN[tampilan]) aturTampilan(tampilan);
    if (aksi === 'tugas-baru') bukaModal();
    if (tampilan || aksi) window.history.replaceState(null, '', '/');
  } catch { /* URL tanpa query — tidak ada yang perlu dilakukan */ }
})();

// Penjadwal notifikasi: periksa pengingat harian dan tugas mepet setiap 30
// detik selama halaman terbuka (sekali di awal dilakukan setelah WASM siap).
setInterval(cekNotifikasi, 30000);

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch((error) => console.warn('Service worker Ordexa gagal didaftarkan.', error));
  });
}
