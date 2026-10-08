/* =========================================================
   Hotel Cabaleón · estadísticas anónimas del blog
   Mismo sistema que index.html: un número al azar por navegador
   (visitante) y por visita (sesion), sin nombres, correos ni IP.
   La visita sigue si la persona pasa de la página principal a un
   artículo (y al revés) en menos de 30 minutos, así el panel sabe
   qué leyó antes de reservar. Envía en lotes al servidor de
   reservas, que lo guarda en Supabase (admin.html → Estadísticas → Blog).
     visita     "blog/<artículo>" o "blog" (la lista de artículos)
     articulo   al abrir el artículo y, al salir, con los segundos de lectura
     lectura    hasta dónde leyó el texto: 25, 50, 75 o 100 %
     blog_clic  enlace tocado: "<artículo>|reservar", "|whatsapp", "|articulo:<otro>"…
   No mide si el navegador pide no ser rastreado ni en los navegadores
   marcados en el panel con "No contar mis visitas".
   ========================================================= */
(() => {
    /* Dirección del servidor de reservas y pagos: la misma de BOLD.servidor en index.html */
    const SERVIDOR = 'https://pagos-cabaleon.hcabaleon.workers.dev';

    const CLAVE_VISITANTE = 'cabaleon-visitante';
    const CLAVE_SESION = 'cabaleon-sesion';
    const MINUTOS_SESION = 30;
    const pagina = document.body.dataset.pagina || 'blog';         // "blog" o "blog/<artículo>"
    const articulo = document.body.dataset.articulo || '';          // "" en la lista de artículos
    const origenClic = articulo || 'lista';

    const permitido = (() => {
        try {
            return !!SERVIDOR && location.protocol !== 'file:' && navigator.doNotTrack !== '1' &&
                !navigator.globalPrivacyControl && localStorage.getItem('cabaleon-no-medir') !== '1';
        } catch (e) { return false; }
    })();
    if (!permitido) return;

    const idAlAzar = () => [...crypto.getRandomValues(new Uint8Array(12))].map(b => 'abcdefghijkmnpqrstuvwxyz23456789'[b % 32]).join('');
    const cola = [];
    let medicion = null;

    /* De dónde llegó la visita (misma lógica que index.html) */
    const FUENTES_POR_SITIO = [
        [/(^|\.)google\./, 'Google', 'Buscador'], [/(^|\.)bing\.com$/, 'Bing', 'Buscador'],
        [/(^|\.)(duckduckgo\.com|yahoo\.com|ecosia\.org)$/, 'Otros buscadores', 'Buscador'],
        [/(^|\.)instagram\.com$/, 'Instagram', 'Redes'], [/(^|\.)(facebook\.com|fb\.com|fb\.me|messenger\.com)$/, 'Facebook', 'Redes'],
        [/(^|\.)(whatsapp\.com|wa\.me)$/, 'WhatsApp', 'Redes'], [/(^|\.)tiktok\.com$/, 'TikTok', 'Redes'],
        [/(^|\.)(t\.co|twitter\.com|x\.com)$/, 'X', 'Redes'], [/(^|\.)youtube\.com$/, 'YouTube', 'Redes'],
        [/(^|\.)tripadvisor\./, 'Tripadvisor', 'Referido'], [/(^|\.)booking\.com$/, 'Booking', 'Referido']
    ];
    const FUENTES_UTM = {
        google: 'Google', facebook: 'Facebook', fb: 'Facebook', instagram: 'Instagram', ig: 'Instagram',
        whatsapp: 'WhatsApp', wa: 'WhatsApp', tiktok: 'TikTok', youtube: 'YouTube', email: 'Correo', correo: 'Correo', qr: 'Código QR'
    };
    const MEDIOS_UTM = {
        cpc: 'Pagado', ppc: 'Pagado', paid: 'Pagado', pagado: 'Pagado', ads: 'Pagado', social: 'Redes', redes: 'Redes',
        email: 'Correo', correo: 'Correo', qr: 'Impreso', impreso: 'Impreso', perfil: 'Perfil del negocio', referral: 'Referido'
    };

    function atributosDeLlegada(nuevo) {
        const q = new URLSearchParams(location.search);
        const utm = k => (q.get('utm_' + k) || '').trim().slice(0, 80);
        let referente = '';
        try {
            const r = new URL(document.referrer);
            if (r.hostname !== location.hostname) referente = r.hostname.replace(/^www\./, '');
        } catch (e) { /* sin sitio de origen */ }
        const porSitio = referente && FUENTES_POR_SITIO.find(([re]) => re.test(referente));
        const ua = navigator.userAgent;
        let fuente = 'Directo', medio = 'Directo';
        if (utm('source')) {
            fuente = FUENTES_UTM[utm('source').toLowerCase()] || utm('source');
            medio = MEDIOS_UTM[utm('medium').toLowerCase()] || utm('medium') || 'Campaña';
        } else if (q.get('gclid') || q.get('gad_source')) {
            fuente = 'Google'; medio = 'Pagado';
        } else if (referente) {
            fuente = porSitio ? porSitio[1] : 'Otros sitios'; medio = porSitio ? porSitio[2] : 'Referido';
        } else if (q.get('fbclid') || /FBAN|FBAV|FB_IAB/.test(ua)) {
            fuente = 'Facebook'; medio = 'Redes';
        } else if (/Instagram/.test(ua)) {
            fuente = 'Instagram'; medio = 'Redes';
        }
        const ipad = /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
        const tablet = ipad || /iPad|Tablet|Android(?!.*Mobile)/i.test(ua);
        return {
            nuevo, fuente, medio, campana: utm('campaign') || undefined, referente: referente || undefined,
            entrada: pagina.slice(0, 60),
            dispositivo: tablet ? 'Tablet' : /Mobi|iPhone|iPod|Android/i.test(ua) ? 'Celular' : 'Computador',
            navegador: /Instagram/.test(ua) ? 'Instagram' : /FBAN|FBAV/.test(ua) ? 'Facebook' : /Edg\//.test(ua) ? 'Edge'
                : /OPR\/|Opera/.test(ua) ? 'Opera' : /SamsungBrowser/.test(ua) ? 'Samsung Internet' : /Firefox\/|FxiOS/.test(ua) ? 'Firefox'
                : /CriOS|Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Otro',
            sistema: /Android/.test(ua) ? 'Android' : (/iPhone|iPad|iPod/.test(ua) || ipad) ? 'iOS' : /Windows/.test(ua) ? 'Windows'
                : /Mac OS X/.test(ua) ? 'macOS' : /CrOS/.test(ua) ? 'ChromeOS' : /Linux/.test(ua) ? 'Linux' : 'Otro',
            idioma: (navigator.language || '').slice(0, 12)
        };
    }

    function guardarSesion() {
        try {
            sessionStorage.setItem(CLAVE_SESION, JSON.stringify({
                id: medicion.sesion, ultimo: Date.now(), atributos: medicion.atributos, vistos: [...medicion.vistos]
            }));
        } catch (e) { /* sin almacenamiento: la visita se mide igual */ }
    }

    function registrar(tipo, detalle, valor) {
        cola.push({
            t: tipo,
            d: detalle == null || detalle === '' ? undefined : String(detalle).slice(0, 80),
            n: Number.isFinite(valor) ? Math.round(valor) : undefined,
            m: Date.now()
        });
        guardarSesion();
        if (cola.length >= 20) enviar();
    }

    function enviar() {
        if (!cola.length) return;
        const cuerpo = JSON.stringify({ v: medicion.visitante, s: medicion.sesion, a: medicion.atributos, e: cola.splice(0, 50) });
        const url = SERVIDOR.replace(/\/+$/, '') + '/eventos';
        try {
            if (navigator.sendBeacon && navigator.sendBeacon(url, new Blob([cuerpo], { type: 'text/plain' }))) return;
        } catch (e) { /* se intenta con fetch */ }
        fetch(url, { method: 'POST', body: cuerpo, keepalive: true, headers: { 'Content-Type': 'text/plain' } }).catch(() => {});
    }

    /* ---------- Visitante y visita (compartidos con index.html) ---------- */
    let visitante = null, nuevo = false;
    try {
        visitante = localStorage.getItem(CLAVE_VISITANTE);
        if (!/^[a-z2-9]{12}$/.test(visitante || '')) { visitante = idAlAzar(); nuevo = true; localStorage.setItem(CLAVE_VISITANTE, visitante); }
    } catch (e) { visitante = idAlAzar(); nuevo = true; }
    let previa = null;
    try { previa = JSON.parse(sessionStorage.getItem(CLAVE_SESION) || 'null'); } catch (e) { /* sin visita previa */ }
    const sigue = previa && previa.id && Date.now() - previa.ultimo < MINUTOS_SESION * 60000 && !/[?&]utm_source=/.test(location.search);
    medicion = sigue
        ? { visitante, sesion: previa.id, atributos: previa.atributos, vistos: new Set(previa.vistos || []) }
        : { visitante, sesion: idAlAzar(), atributos: atributosDeLlegada(nuevo), vistos: new Set() };

    registrar('visita', pagina);
    if (articulo) registrar('articulo', articulo);

    /* ---------- Hasta dónde leen el texto del artículo ---------- */
    const texto = document.querySelector('[data-texto]');
    if (articulo && texto) {
        let pendiente = false;
        const revisarAvance = () => {
            pendiente = false;
            const caja = texto.getBoundingClientRect();
            if (caja.height <= 0) return;
            const visto = Math.max(0, Math.min(1, (window.innerHeight - caja.top) / caja.height));
            [25, 50, 75, 100].forEach(hito => {
                const clave = 'lectura:' + articulo + ':' + hito;
                if (visto * 100 >= hito - 0.5 && !medicion.vistos.has(clave)) {
                    medicion.vistos.add(clave);
                    registrar('lectura', articulo, hito);
                }
            });
        };
        window.addEventListener('scroll', () => { if (!pendiente) { pendiente = true; requestAnimationFrame(revisarAvance); } }, { passive: true });
        window.addEventListener('resize', revisarAvance);
        revisarAvance();
    }

    /* ---------- Enlaces tocados ---------- */
    const DESTINOS_PORTADA = ['reservar', 'habitaciones', 'planes', 'eventos', 'restaurante', 'bar', 'servicios', 'galeria', 'contacto', 'faq', 'informacion'];
    document.addEventListener('click', e => {
        const a = e.target.closest && e.target.closest('a[href]');
        if (!a) return;
        const href = a.getAttribute('href') || '';
        const lugar = 'blog:' + origenClic;
        const clic = destino => registrar('blog_clic', origenClic + '|' + destino);
        if (/^https:\/\/(wa\.me|api\.whatsapp\.com)\//.test(href)) { registrar('whatsapp', lugar); clic('whatsapp'); }
        else if (/^tel:/.test(href)) { registrar('llamada', lugar); clic('llamada'); }
        else if (/^mailto:/.test(href)) { registrar('correo', lugar); clic('correo'); }
        else if (/google\.[^/]+\/maps|maps\.app\.goo\.gl|waze\.com/.test(href)) { registrar('como_llegar', lugar); clic('mapa'); }
        else if (/\.pdf(\?|#|$)/i.test(href)) { registrar('documento', href.replace(/^.*\//, '').replace(/\.pdf.*$/i, '')); clic('documento'); }
        else if (a.dataset.articulo) clic('articulo:' + a.dataset.articulo);
        else if (/^blog\.html/.test(href)) clic('blog');
        else if (/^index\.html/.test(href)) {
            const ancla = (href.split('#')[1] || '').toLowerCase();
            clic(DESTINOS_PORTADA.includes(ancla) ? ancla : 'inicio');
        } else {
            const red = /instagram|facebook|tiktok|youtube|tripadvisor/.exec(href);
            if (red) { registrar('red_social', red[0]); clic('redes'); }
        }
    }, true);

    /* ---------- Tiempo de lectura (solo con la página a la vista) y envío ---------- */
    let segundosActivos = 0;
    let segundosEnviados = 0;
    let activoDesde = document.visibilityState === 'visible' ? Date.now() : null;
    const cerrarTramo = () => {
        if (activoDesde) { segundosActivos += (Date.now() - activoDesde) / 1000; activoDesde = null; }
        const nuevos = Math.round(segundosActivos - segundosEnviados);
        if (articulo && nuevos >= 1) {
            registrar('articulo', articulo, Math.min(nuevos, 3600));   // se suman en el panel
            segundosEnviados += nuevos;
        }
        if (segundosActivos >= 1) registrar('salida', null, Math.min(segundosActivos, 7200));
        enviar();
    };
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') cerrarTramo();
        else activoDesde = Date.now();
    });
    window.addEventListener('pagehide', cerrarTramo);
    setInterval(enviar, 8000);
})();
