// Offline support for the installable web app (PWA).
//
// Network first for everything: online you always get the latest deploy,
// offline the copy from your last visit. Successful GET responses are
// cached, including AutoEQ data fetched from GitHub, so headphone models
// opened before stay usable offline.
//
// Registered by index.html. Flutter's own flutter_service_worker.js is
// deprecated (it only unregisters itself), so web/flutter_bootstrap.js
// doesn't load it.
'use strict';

const CACHE = 'eqloader-v1';

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) {
        if (key !== CACHE) await caches.delete(key);
      }
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' || !request.url.startsWith('http')) return;
  event.respondWith(
    (async () => {
      try {
        const response = await fetch(request);
        // 200 only: partial (206) and opaque responses can't be replayed.
        if (response.status === 200 &&
            (response.type === 'basic' || response.type === 'cors')) {
          const copy = response.clone();
          event.waitUntil(
            caches.open(CACHE).then((cache) => cache.put(request, copy)),
          );
        }
        return response;
      } catch (error) {
        const cached = await caches.match(request, {
          // Offline, "/?foo" should still open the app.
          ignoreSearch: request.mode === 'navigate',
        });
        if (cached) return cached;
        throw error;
      }
    })(),
  );
});
