/* aprovi.ai — service worker do app shell.
 *
 * 🔴 REGRA QUE NÃO PODE QUEBRAR
 * Este SW só toca em arquivo ESTÁTICO DA PRÓPRIA ORIGEM (HTML, CSS, JS, ícone).
 * Resposta do Supabase (API, RPC, Auth) e mídia do Storage NUNCA entram no
 * cache — nem como fallback. Um cache agressivo aqui faria a Luciana aprovar
 * conteúdo velho, que é o pior erro possível neste produto.
 *
 * Estratégia do shell: NETWORK-FIRST com fallback pro cache.
 * Online = sempre o arquivo recém-publicado no GitHub Pages (deploy não fica
 * preso). Offline = a tela abre, e o próprio app avisa que está sem conexão.
 *
 * Chave de cache = origem + pathname, com a query string DESCARTADA. Assim o
 * `?t=<secret_token>` do cliente.html nunca é persistido no Cache Storage.
 */

const VERSION = 'v1';
const SHELL_CACHE = 'aprovi-shell-' + VERSION;

const SHELL = [
  './',
  './index.html',
  './cliente.html',
  './style.css',
  './config.js',
  './manifest.webmanifest',
  './manifest-cliente.webmanifest',
  './assets/favicon.svg',
  './assets/favicon-32.png',
  './assets/panda.svg',
  './assets/icon-192.png',
  './assets/icon-512.png',
  './assets/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    // add() individual e tolerante: um 404 num ícone não pode derrubar
    // a instalação inteira do SW (addAll() é tudo-ou-nada).
    await Promise.all(SHELL.map((url) => cache.add(url).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const nomes = await caches.keys();
    await Promise.all(
      nomes.filter((n) => n.startsWith('aprovi-shell-') && n !== SHELL_CACHE)
           .map((n) => caches.delete(n))
    );
    await self.clients.claim();
  })());
});

function chaveDeCache(url) {
  // sem query string: o token do cliente nunca é gravado
  return url.origin + url.pathname;
}

self.addEventListener('fetch', (event) => {
  const req = event.request;

  // Só GET. POST (RPC do Supabase) passa direto, sempre.
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (_) { return; }

  // Outra origem (supabase.co, cdn.jsdelivr.net, Storage) → rede pura,
  // sem interceptar. É esta linha que garante dado fresco.
  if (url.origin !== self.location.origin) return;

  // Cinto e suspensório: mesmo que um dia o Supabase passe a servir de um
  // domínio próprio apontado pra cá, nada com cara de API é cacheado.
  if (/supabase|\/rest\/|\/auth\/|\/storage\//.test(url.pathname)) return;

  event.respondWith((async () => {
    const cache = await caches.open(SHELL_CACHE);
    const chave = chaveDeCache(url);
    try {
      const fresca = await fetch(req);
      if (fresca && fresca.ok && fresca.type === 'basic') {
        cache.put(chave, fresca.clone());
      }
      return fresca;
    } catch (erro) {
      const guardada = await cache.match(chave);
      if (guardada) return guardada;
      // navegação offline sem cache do caminho exato: devolve a casca mais
      // próxima pra tela abrir e mostrar o aviso de "sem conexão".
      if (req.mode === 'navigate') {
        const fallback = await cache.match(self.location.origin + '/index.html');
        if (fallback) return fallback;
      }
      throw erro;
    }
  })());
});
