// AzimutCP Service Worker
// Strategy:
//   - API calls (/api/):   network only, never cached
//   - Navigation/HTML:     network only (never cache the SPA shell — a stale
//                          shell references old hashed assets and breaks the UI)
//   - Static assets:       cache-first (filenames are content-hashed/immutable)
//   - WebSocket:           passthrough (SW cannot intercept)
//
// Bump CACHE_NAME whenever the caching strategy changes.

const CACHE_NAME = 'azimutcp-v3';
const PRECACHE = [
    '/manifest.json',
    '/favicon.svg',
    '/icon.svg',
    '/icon-192.png',
    '/icon-512.png',
];

// ── Install ───────────────────────────────────────────────────────────────────

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME).then((cache) =>
            cache.addAll(PRECACHE).catch((err) => {
                console.warn('SW: pre-cache partial failure (ok):', err);
            })
        )
    );
    self.skipWaiting();
});

// ── Activate: drop every cache from older versions ────────────────────────────

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then((keys) =>
                Promise.all(
                    keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
                )
            )
            .then(() => self.clients.claim())
    );
});

// ── Fetch ─────────────────────────────────────────────────────────────────────

self.addEventListener('fetch', (event) => {
    const url = new URL(event.request.url);

    if (url.origin !== self.location.origin) return;

    // API: always network.
    if (url.pathname.startsWith('/api/')) {
        event.respondWith(fetch(event.request));
        return;
    }

    // Never intercept navigations or the service worker itself. Serving a
    // cached shell after an upgrade is the main cause of "blank page" bugs.
    if (event.request.mode === 'navigate' || url.pathname === '/sw.js') {
        return;
    }

    // Immutable static assets: cache-first.
    if (/\.(js|css|png|jpg|jpeg|svg|ico|woff2?|ttf)$/.test(url.pathname)) {
        event.respondWith(
            caches.match(event.request).then((cached) => cached || fetchAndCache(event.request))
        );
        return;
    }

    // Everything else: network, cache as a fallback for static files only.
    event.respondWith(
        fetch(event.request).catch(() =>
            caches.match(event.request).then((cached) => cached || Response.error())
        )
    );
});

async function fetchAndCache(request) {
    const response = await fetch(request);
    if (response.ok) {
        const cache = await caches.open(CACHE_NAME);
        cache.put(request, response.clone());
    }
    return response;
}

// ── Push notifications ────────────────────────────────────────────────────────

self.addEventListener('push', (event) => {
    if (!event.data) return;

    let data;
    try {
        data = event.data.json();
    } catch {
        data = { title: 'AzimutCP', body: event.data.text() };
    }

    const options = {
        body: data.body || '',
        icon: '/icon-192.png',
        badge: '/icon-192.png',
        tag: data.tag || 'azimutcp',
        data: { url: data.url || '/dashboard' },
        actions: data.actions || [],
    };

    event.waitUntil(
        self.registration.showNotification(data.title || 'AzimutCP Alert', options)
    );
});

self.addEventListener('notificationclick', (event) => {
    event.notification.close();
    const targetUrl = event.notification.data?.url || '/dashboard';

    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
            for (const client of clientList) {
                if (client.url === targetUrl && 'focus' in client) {
                    return client.focus();
                }
            }
            if (clients.openWindow) {
                return clients.openWindow(targetUrl);
            }
        })
    );
});
