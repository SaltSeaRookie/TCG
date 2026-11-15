/* 鹽海新鮮人 集換式卡牌遊戲 — offline support
   - The game page is fetched network-first, so a new index.html on GitHub reaches players right away;
     when offline the cached copy is used.
   - Icons / manifest are cached on install; fonts and other CDN files are cached the first time they load.
   - Requests carrying ?vc= (the in-game version check) always go to the network. */
const CACHE = 'yjn-tcg-v1';
const CORE = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k.startsWith('yjn-tcg-') && k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.searchParams.has('vc')) return;                       // version check: network only
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
  if (/peerjs|0\.peerjs\.com/.test(url.hostname)) return;      // live connection server: never cache

  const isPage = req.mode === 'navigate' || (url.origin === location.origin && /\/(index\.html)?$/.test(url.pathname));
  if (isPage) {
    e.respondWith(
      fetch(req).then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put('./index.html', copy)); }
        return res;
      }).catch(() => caches.match('./index.html').then(r => r || caches.match('./')))
    );
    return;
  }
  // everything else: cache first, then network (and remember it)
  e.respondWith(
    caches.match(req, { ignoreSearch: url.origin === location.origin }).then(hit => {
      if (hit) return hit;
      return fetch(req).then(res => {
        if (res && (res.ok || res.type === 'opaque')) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
        return res;
      });
    })
  );
});
