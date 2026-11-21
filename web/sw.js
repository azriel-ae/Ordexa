/* Service worker Ordexa — tembolok app-shell mengutamakan offline. */
'use strict';

const CACHE_VERSION = 'ordexa-v12';
const APP_SHELL = [
  '/',
  '/index.html',
  '/styles.css',
  '/app.js',
  '/ordexa-core.wasm',
  '/favicon.svg',
  '/manifest.webmanifest',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/icon-maskable-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET' || !request.url.startsWith(self.location.origin)) return;

  // Tembolok lebih dulu untuk GET satu asal; jaringan menyegarkan tembolok di latar belakang.
  event.respondWith(
    caches.match(request, { ignoreSearch: request.mode === 'navigate' }).then((cached) => {
      const network = fetch(request).then((response) => {
        if (response && response.status === 200 && response.type === 'basic') {
          const copy = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy));
        }
        return response;
      }).catch(() => undefined);

      if (cached) {
        event.waitUntil(network);
        return cached;
      }
      return network.then((response) => response || caches.match('/index.html'));
    })
  );
});

// Klik notifikasi Ordexa: fokuskan jendela yang sudah terbuka, atau buka baru.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((daftar) => {
      for (const klien of daftar) {
        if ('focus' in klien) return klien.focus();
      }
      return self.clients.openWindow('/');
    })
  );
});
