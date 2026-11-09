// Service worker mínimo: permite instalar o TMR Gestão Comercial como aplicativo.
// Não guarda páginas em cache — o sistema sempre carrega a versão mais recente.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
