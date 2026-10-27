const CACHE_NAME = 'kies-drive-shell-v1';
const SHELL = [
  '/',
  '/manifest.webmanifest',
  '/web/style.css',
  '/web/app.js',
  '/web/icon-180.png',
  '/web/icon-192.png',
  '/web/icon-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(
    keys.filter((key) => key.startsWith('kies-drive-shell-') && key !== CACHE_NAME)
      .map((key) => caches.delete(key))
  )));
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  // Never store account data, commands, telemetry, or authentication responses.
  if (/^\/(auth|oauth|api|mcp)(\/|$)/.test(url.pathname)) return;
  if (!SHELL.includes(url.pathname)) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      const response = await fetch(request);
      if (response.ok && response.type === 'basic') cache.put(request, response.clone());
      return response;
    } catch (_) {
      return (await cache.match(request)) || (await cache.match('/')) || Response.error();
    }
  })());
});
