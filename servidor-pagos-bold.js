/* =====================================================================
   Servidor de reservas y pagos Bold · Hotel Cabaleón
   ---------------------------------------------------------------------
   Se publica como un Cloudflare Worker (plan gratuito). Hace lo que la
   página no puede hacer sola porque requiere llaves secretas:

     POST /firma           Recalcula la factura de la reserva (una o varias
                           habitaciones) con las tarifas publicadas, revisa
                           el cupo, guarda la reserva y firma el valor a
                           cobrar (anticipo o total) con el hash SHA-256 que
                           exige Bold.
     POST /reserva         Guarda una reserva de pago asistido (WhatsApp).
     GET  /disponibilidad  Habitaciones libres de cada tipo entre dos fechas
                           (?llegada=AAAA-MM-DD&salida=AAAA-MM-DD).
     GET  /estado          Consulta en Bold el estado real de un pago
                           (?orden=CAB-...) y lo anota en la reserva.
     POST /webhook-bold    Aviso automático de Bold cuando un pago se aprueba,
                           se rechaza o se anula (panel de Bold →
                           Integraciones → Webhooks).
     POST /eventos         Estadísticas anónimas de la página y del blog
                           (visitas, de dónde llegan, clics, artículos leídos
                           y pasos de la reserva) para el panel. Agrega país
                           y ciudad aproximados.
     GET  /                Estado del servidor. Incluye la versión y los tipos
                           de evento que acepta: el panel la consulta para
                           avisar si falta publicar esta versión en Cloudflare.

   Variables del Worker (Settings → Variables and Secrets):
     BOLD_LLAVE_IDENTIDAD    Llave de identidad de Bold (texto).
     BOLD_LLAVE_SECRETA      Llave secreta de Bold (tipo "Secret").
     SITIO_URL               Dirección pública de la página, sin barra final.
                             Ej.: https://hotelcabaleon.com
     SUPABASE_URL            Project URL de Supabase (https://xxxx.supabase.co).
     SUPABASE_LLAVE_SECRETA  Secret key de Supabase (sb_secret_…), tipo "Secret".
                             Sin las dos de Supabase el cobro funciona igual,
                             pero las reservas no se guardan ni se revisa el cupo.
     BOLD_PRUEBAS            Solo mientras se usan las llaves de PRUEBAS de Bold:
                             "si" (Bold firma sus avisos de prueba con una llave
                             vacía). Se borra al pasar a producción.
     ORIGENES_PERMITIDOS     Opcional. Otras direcciones desde las que se puede
                             reservar, separadas por coma (pruebas).

   Las tarifas NO se copian aquí: el servidor las lee de index.html
   (TARIFAS, UNIDADES, TARIFA_MASCOTA, ANTICIPO, FESTIVOS y CODIGOS_PROMO), así que
   se siguen cambiando en un solo lugar. Nadie puede pagar un valor
   distinto al que corresponde, aunque modifique la página en su navegador.

   Cupo de cada tipo: UNIDADES menos las reservas pagadas o confirmadas que
   se cruzan con las fechas, y las de pago en línea que se están pagando
   (pendientes de los últimos MINUTOS_PAGO_EN_CURSO minutos).
   ===================================================================== */

const VERSION = '2026-10-08';   // se muestra en GET /; súbela al publicar cambios
const MONEDA = 'COP';
const BOLD_API = 'https://payments.api.bold.co/v2/payment-voucher/';
const MINUTOS_CACHE_TARIFAS = 5;
const MINUTOS_PAGO_EN_CURSO = 30;
const ESTADO_SEGUN_BOLD = { APPROVED: 'pagada', REJECTED: 'rechazada', FAILED: 'rechazada', VOIDED: 'anulada' };
const ORDEN_WEB = /^CAB-\d{6}-[A-Z2-9]{6}$/;

let cacheTarifas = { hasta: 0, datos: null };

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const origen = request.headers.get('Origin');
        const cabeceras = cabecerasCors(origen, env);

        if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cabeceras });

        /* Estadísticas: se responde de una vez y se guardan después, sin hacer esperar a la página */
        if (url.pathname === '/eventos' && request.method === 'POST') {
            if (origenPermitido(origen, env)) {
                const cuerpo = await request.text();
                const tarea = guardarEventos(cuerpo, request, env).catch(e => console.log('No se guardaron eventos: ' + e.message));
                if (ctx && ctx.waitUntil) ctx.waitUntil(tarea); else await tarea;
            }
            return new Response(null, { status: 204, headers: cabeceras });
        }

        try {
            if (url.pathname === '/webhook-bold' && request.method === 'POST') {
                return json(await avisoDeBold(request, env), 200, {});
            }
            if (url.pathname === '/firma' && request.method === 'POST') {
                if (!origenPermitido(origen, env)) throw error(403, 'Origen no autorizado.');
                return json(await crearPago(await leerJson(request), env), 200, cabeceras);
            }
            if (url.pathname === '/reserva' && request.method === 'POST') {
                if (!origenPermitido(origen, env)) throw error(403, 'Origen no autorizado.');
                return json(await crearReservaAsistida(await leerJson(request), env), 200, cabeceras);
            }
            if (url.pathname === '/disponibilidad' && request.method === 'GET') {
                return json(await disponibilidad(url.searchParams, env), 200, cabeceras);
            }
            if (url.pathname === '/estado' && request.method === 'GET') {
                return json(await consultarEstado(url.searchParams.get('orden'), env), 200, cabeceras);
            }
            if (url.pathname === '/') {
                return json({
                    ok: true, servicio: 'Reservas y pagos Bold · Hotel Cabaleón', version: VERSION,
                    configurado: boldConfigurado(env), reservas: reservasConfiguradas(env),
                    eventos: [...TIPOS_EVENTO]
                }, 200, cabeceras);
            }
            return json({ error: 'Ruta no encontrada.' }, 404, cabeceras);
        } catch (e) {
            if (!e.publico) console.log(e.stack || e.message);
            return json({
                error: e.publico || 'No pudimos preparar el pago. Intenta de nuevo en unos minutos.',
                ...(e.extra || {})
            }, e.status || 500, cabeceras);
        }
    }
};

/* ---------------------------------------------------------------- Pago en línea */
async function crearPago(d, env) {
    if (!boldConfigurado(env)) throw error(503, 'El pago en línea aún no está configurado.');
    const t = await leerTarifas(env);
    const r = cotizar(d, t);
    await revisarCupo(r, t, env, d.excluir);

    const orden = nuevaOrden();
    const firma = await sha256(orden + r.monto + MONEDA + env.BOLD_LLAVE_SECRETA);
    await guardarReserva(env, filaReserva(r, orden, 'bold'));

    let resumen = limpiar(d.resumen, 200) || r.elegidas.map(k => k + ' x' + r.cantidades[k]).join(', ');
    if (resumen.length > 48) resumen = resumen.slice(0, 47).replace(/[\s,·]+\S*$/, '') + '…';
    const porcentaje = Math.round(t.anticipo * 100);

    return {
        orden,
        monto: r.monto,
        moneda: MONEDA,
        firma,
        llave: env.BOLD_LLAVE_IDENTIDAD,
        total: r.total,
        anticipo: r.anticipo,
        modalidad: r.modalidad,
        noches: r.noches,
        porcentaje,
        descripcion: ((r.modalidad === 'total' ? 'Pago total' : 'Anticipo ' + porcentaje + '%') + ' · ' + resumen + ' · ' + corta(r.llegada) + ' al ' + corta(r.salida)).slice(0, 100),
        extra1: (r.elegidas.map(k => k + r.cantidades[k]).join(' ') + ' ' + r.llegada + '>' + r.salida.slice(5) + ' ' + r.huespedes + 'p' + (r.mascotas ? ' ' + r.mascotas + 'm' : '')).slice(0, 60),
        extra2: (r.nombre + ' · ' + r.celular).slice(0, 60)
    };
}

/* ---------------------------------------------------------------- Pago asistido (WhatsApp)
   La página abre WhatsApp con el número de orden y, al mismo tiempo, deja
   la reserva guardada para el panel con ese mismo número. */
async function crearReservaAsistida(d, env) {
    if (!env.SITIO_URL) throw error(503, 'El servidor de reservas aún no está configurado.');
    const t = await leerTarifas(env);
    const r = cotizar(d, t);
    const orden = ORDEN_WEB.test(String(d.orden || '')) ? d.orden : nuevaOrden();
    const guardada = await guardarReserva(env, filaReserva(r, orden, 'whatsapp'));
    return { orden, guardada, total: r.total };
}

/* Valida la reserva y la cotiza con las tarifas publicadas.
   Mismo cálculo que estimarEstadia() en index.html */
function cotizar(d, t) {
    const pedidas = d.habitaciones && typeof d.habitaciones === 'object' ? d.habitaciones : {};
    const elegidas = Object.keys(pedidas).filter(k => Number(pedidas[k]) > 0);
    if (!elegidas.length) throw error(400, 'Elige al menos una habitación.');
    const cantidades = {};
    for (const k of elegidas) {
        const n = entero(pedidas[k], 1, 20);
        if (!t.tarifas[k] || n === null) throw error(400, 'Elige habitaciones válidas.');
        if (t.unidades[k] !== undefined && n > t.unidades[k]) throw error(400, 'No hay tantas habitaciones de ese tipo para una sola reserva.');
        cantidades[k] = n;
    }
    const modalidad = d.modalidad === 'total' ? 'total' : 'anticipo';
    const { llegada, salida, noches } = validarFechas(d.llegada, d.salida);

    const huespedes = entero(d.huespedes, 1, 60);
    const mascotas = entero(d.mascotas, 0, 3);
    if (huespedes === null || mascotas === null) throw error(400, 'Revisa huéspedes y mascotas.');

    const nombre = limpiar(d.nombre, 60);
    const correo = String(d.correo || '').trim().slice(0, 80);
    const celular = String(d.celular || '').replace(/\D/g, '');
    if (nombre.length < 3) throw error(400, 'Escribe tu nombre completo.');
    if (!/^[^\s@<>"'`\\]+@[^\s@<>"'`\\]+\.[^\s@<>"'`\\]{2,}$/.test(correo)) throw error(400, 'Escribe un correo válido.');
    if (celular.length < 7 || celular.length > 15) throw error(400, 'Escribe un celular válido.');

    let finde = 0;
    for (let i = 0; i < noches; i++) {
        const noche = sumarDias(llegada, i);
        const dia = fecha(noche).getUTCDay();
        if (dia === 5 || dia === 6 || t.festivos.has(sumarDias(noche, 1))) finde++;
    }
    let alojamiento = 0;
    for (const k of elegidas) {
        alojamiento += cantidades[k] * (finde * t.tarifas[k].finde + (noches - finde) * t.tarifas[k].semana);
    }
    const codigo = String(d.codigo || '').trim().toUpperCase();
    const promo = t.promos[codigo];
    const descuento = promo && promo.activo ? Math.round(alojamiento * promo.descuento / 100) : 0;
    const total = alojamiento - descuento + mascotas * t.mascota * noches;
    const anticipo = Math.round(total * t.anticipo);
    const monto = modalidad === 'total' ? total : anticipo;
    if (monto < 1000) throw error(400, 'El valor a pagar no es válido.');

    return {
        cantidades, elegidas, modalidad, llegada, salida, noches, huespedes, mascotas,
        nombre, correo, celular, codigo: descuento ? codigo : '',
        tipoDocumento: limpiar(d.tipoDocumento, 10), documento: limpiar(d.documento, 20),
        total, anticipo, monto
    };
}

function validarFechas(a, b) {
    const llegada = String(a || '');
    const salida = String(b || '');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(llegada) || !/^\d{4}-\d{2}-\d{2}$/.test(salida)) throw error(400, 'Revisa las fechas de tu reserva.');
    const hoy = hoyEnColombia();
    if (llegada < hoy) throw error(400, 'La fecha de llegada ya pasó. Elige otra fecha.');
    if (llegada > sumarDias(hoy, 730)) throw error(400, 'Por ahora recibimos reservas hasta dos años adelante.');
    const noches = Math.round((fecha(salida) - fecha(llegada)) / 86400000);
    if (!(noches >= 1 && noches <= 29)) throw error(400, 'La estadía debe ser de 1 a 29 noches.');
    return { llegada, salida, noches };
}

const filaReserva = (r, orden, canal) => ({
    orden, canal, estado: 'pendiente',
    llegada: r.llegada, salida: r.salida, noches: r.noches,
    habitaciones: r.cantidades, huespedes: r.huespedes, mascotas: r.mascotas,
    codigo: r.codigo || null, modalidad: r.modalidad, total: r.total, monto: r.monto,
    nombre: r.nombre, tipo_documento: r.tipoDocumento || null, documento: r.documento || null,
    celular: r.celular, correo: r.correo
});

/* ---------------------------------------------------------------- Cupo */
async function disponibilidad(q, env) {
    if (!env.SITIO_URL) throw error(503, 'El servidor de reservas aún no está configurado.');
    const llegada = String(q.get('llegada') || '');
    const salida = String(q.get('salida') || '');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(llegada) || !/^\d{4}-\d{2}-\d{2}$/.test(salida) || salida <= llegada) throw error(400, 'Revisa las fechas.');
    if ((fecha(salida) - fecha(llegada)) / 86400000 > 60) throw error(400, 'Consulta hasta 60 noches.');
    const t = await leerTarifas(env);
    return { llegada, salida, libres: await habitacionesLibres(llegada, salida, t, env, q.get('excluir')) };
}

/* Si alguna habitación ya no está libre en esas fechas, no se cobra */
async function revisarCupo(r, t, env, excluir) {
    const libres = await habitacionesLibres(r.llegada, r.salida, t, env, excluir);
    if (!libres) return;
    if (r.elegidas.some(k => r.cantidades[k] > libres[k])) {
        const e = error(409, 'Ya no hay cupo para alguna de tus habitaciones en esas fechas. Revisa tu reserva y vuelve a intentarlo.');
        e.extra = { libres };
        throw e;
    }
}

/* Habitaciones libres de cada tipo entre dos fechas.
   null: no hay base de datos o no respondió (la reserva sigue sin límite). */
async function habitacionesLibres(llegada, salida, t, env, excluir) {
    if (!reservasConfiguradas(env)) return null;
    let filas;
    try {
        filas = await supabase(env, 'GET', 'reservas?select=orden,habitaciones,llegada,salida,estado,canal,creada' +
            '&llegada=lt.' + salida + '&salida=gt.' + llegada + '&estado=in.(pagada,confirmada,pendiente)');
    } catch (e) {
        console.log('No se pudo revisar el cupo: ' + e.message);
        return null;
    }
    const limite = Date.now() - MINUTOS_PAGO_EN_CURSO * 60000;
    const ocupan = filas.filter(f => f.orden !== excluir &&
        (f.estado !== 'pendiente' || (f.canal === 'bold' && Date.parse(f.creada) > limite)));
    const libres = {};
    for (const k of Object.keys(t.tarifas)) {
        let maximo = 0;
        for (let noche = llegada; noche < salida; noche = sumarDias(noche, 1)) {
            let ocupadas = 0;
            for (const f of ocupan) {
                if (f.llegada <= noche && noche < f.salida) ocupadas += Number((f.habitaciones || {})[k]) || 0;
            }
            maximo = Math.max(maximo, ocupadas);
        }
        libres[k] = t.unidades[k] === undefined ? 99 : Math.max(0, t.unidades[k] - maximo);
    }
    return libres;
}

/* ---------------------------------------------------------------- Estado de un pago */
async function consultarEstado(orden, env) {
    if (!boldConfigurado(env)) throw error(503, 'El pago en línea aún no está configurado.');
    if (!/^CAB-[A-Z0-9-]{4,50}$/.test(orden || '')) throw error(400, 'Número de orden inválido.');
    const pago = await estadoEnBold(orden, env);
    try {
        await anotarPago(orden, pago, env);
    } catch (e) {
        console.log('No se pudo anotar el pago ' + orden + ': ' + e.message);
    }
    return { orden, estado: pago.estado, total: pago.total, metodo: pago.metodo, fecha: pago.fecha };
}

async function estadoEnBold(orden, env) {
    const r = await fetch(BOLD_API + encodeURIComponent(orden), {
        headers: { Authorization: 'x-api-key ' + env.BOLD_LLAVE_IDENTIDAD }
    });
    if (r.status === 404) return { estado: 'NO_TRANSACTION_FOUND' };
    if (!r.ok) throw error(502, 'Bold no respondió la consulta del pago.');
    const b = await r.json();
    return {
        estado: b.payment_status || 'NO_TRANSACTION_FOUND',
        total: b.total,
        metodo: b.payment_method,
        fecha: b.transaction_date,
        transaccion: b.transaction_id
    };
}

/* Anota en la reserva lo que Bold informa del pago */
async function anotarPago(orden, pago, env) {
    const estado = ESTADO_SEGUN_BOLD[pago.estado];
    if (!estado || !reservasConfiguradas(env)) return;
    const cambios = { estado, metodo_pago: pago.metodo || null, bold_transaccion: pago.transaccion || null };
    if (estado === 'pagada') cambios.pagado = Math.round(Number(pago.total) || 0);
    /* Un intento rechazado no cambia una reserva que ya está pagada, confirmada o cancelada */
    const filtro = 'orden=eq.' + encodeURIComponent(orden) + (estado === 'rechazada' ? '&estado=eq.pendiente' : '');
    await supabase(env, 'PATCH', 'reservas?' + filtro, cambios, { Prefer: 'return=minimal' });
}

/* ---------------------------------------------------------------- Aviso automático de Bold (webhook)
   Se verifica la firma del aviso y, para no depender de su contenido, el
   estado del pago se vuelve a consultar en Bold antes de anotarlo. */
async function avisoDeBold(request, env) {
    if (!boldConfigurado(env)) throw error(503, 'El pago en línea aún no está configurado.');
    const crudo = new Uint8Array(await request.arrayBuffer());
    const firma = (request.headers.get('x-bold-signature') || '').trim().toLowerCase();
    /* En modo de pruebas Bold firma con una llave vacía; en HMAC equivale a 64 bytes en cero */
    const llave = env.BOLD_PRUEBAS === 'si' ? new Uint8Array(64) : new TextEncoder().encode(env.BOLD_LLAVE_SECRETA);
    if (!firma || !igualSeguro(firma, await hmacSha256(llave, aBase64(crudo)))) throw error(401, 'Firma inválida.');

    let aviso;
    try { aviso = JSON.parse(new TextDecoder().decode(crudo)); } catch (e) { throw error(400, 'Aviso inválido.'); }
    const orden = String((aviso.data && aviso.data.metadata && aviso.data.metadata.reference) || '');
    if (!/^CAB-[A-Z0-9-]{4,50}$/.test(orden)) return { ok: true, ignorado: 'No es un pago de la página.' };

    const pago = await estadoEnBold(orden, env);
    /* Si Bold aún no refleja la aprobación, se responde con error para que reintente en 15 minutos */
    if (aviso.type === 'SALE_APPROVED' && pago.estado !== 'APPROVED') throw error(503, 'Bold aún no confirma el pago.');
    await anotarPago(orden, pago, env);
    return { ok: true };
}

/* ---------------------------------------------------------------- Estadísticas de la página
   La página envía lotes { v: visitante, s: sesion, a: {fuente, medio…}, e: [{t, d, n, m}] }.
   Nada personal: identificadores al azar, la fuente de la visita y lo que hizo. */
const TIPOS_EVENTO = new Set([
    'visita', 'seccion', 'salida', 'whatsapp', 'llamada', 'correo', 'como_llegar', 'red_social', 'documento',
    'ficha_habitacion', 'galeria', 'plan', 'asistente', 'asistente_tema', 'pedido_mangole', 'fechas',
    'habitacion_agregada', 'carrito', 'datos_completos', 'reserva_whatsapp', 'pago_iniciado', 'pago',
    /* Blog: tarjeta tocada en la portada, artículo abierto (y segundos de lectura), hasta dónde lo leyeron
       (25, 50, 75 o 100 %) y enlaces tocados dentro del artículo */
    'blog', 'articulo', 'lectura', 'blog_clic'
]);
const DIAS_EVENTOS = 400;

async function guardarEventos(cuerpo, request, env) {
    if (!reservasConfiguradas(env) || cuerpo.length > 64000) return;
    if (/bot|crawl|spider|slurp|headless|lighthouse|pagespeed|preview|facebookexternalhit|whatsapp\//i.test(request.headers.get('User-Agent') || '')) return;
    let d;
    try { d = JSON.parse(cuerpo); } catch (e) { return; }
    const id = s => (/^[A-Za-z0-9]{8,32}$/.test(String(s || '')) ? String(s) : null);
    if (!d || !id(d.v) || !id(d.s) || !Array.isArray(d.e)) return;
    const a = d.a && typeof d.a === 'object' ? d.a : {};
    const texto = (s, max) => (s == null || s === '' ? null : limpiar(s, max) || null);
    const cf = request.cf || {};
    const comun = {
        visitante: id(d.v), sesion: id(d.s), nuevo: a.nuevo === true,
        fuente: texto(a.fuente, 40), medio: texto(a.medio, 40), campana: texto(a.campana, 80),
        referente: texto(a.referente, 80), entrada: texto(a.entrada, 60), dispositivo: texto(a.dispositivo, 20),
        navegador: texto(a.navegador, 30), sistema: texto(a.sistema, 30), idioma: texto(a.idioma, 12),
        pais: /^[A-Z]{2}$/.test(cf.country || '') ? cf.country : null, ciudad: texto(cf.city, 60)
    };
    const ahora = Date.now();
    const filas = d.e.slice(0, 60).filter(e => e && TIPOS_EVENTO.has(e.t)).map(e => ({
        ...comun,
        tipo: e.t,
        detalle: texto(e.d, 80),
        valor: Number.isFinite(e.n) ? Math.max(-2e9, Math.min(2e9, Math.round(e.n))) : null,
        creado: new Date(Math.min(ahora, Math.max(ahora - 3600000, Number(e.m) || ahora))).toISOString()
    }));
    if (!filas.length) return;
    await supabase(env, 'POST', 'eventos', filas, { Prefer: 'return=minimal' });
    /* De vez en cuando se borran los eventos de hace más de DIAS_EVENTOS días */
    if (Math.random() < 0.002) {
        await supabase(env, 'DELETE', 'eventos?creado=lt.' + new Date(ahora - DIAS_EVENTOS * 86400000).toISOString(), undefined, { Prefer: 'return=minimal' })
            .catch(e => console.log('No se borraron eventos viejos: ' + e.message));
    }
}

/* ---------------------------------------------------------------- Base de datos (Supabase) */
async function guardarReserva(env, fila) {
    if (!reservasConfiguradas(env)) return false;
    try {
        await supabase(env, 'POST', 'reservas?on_conflict=orden', fila, { Prefer: 'resolution=ignore-duplicates,return=minimal' });
        return true;
    } catch (e) {
        console.log('No se pudo guardar la reserva ' + fila.orden + ': ' + e.message);
        return false;
    }
}

async function supabase(env, metodo, ruta, cuerpo, extra) {
    const llave = env.SUPABASE_LLAVE_SECRETA;
    const cabeceras = { apikey: llave, 'Content-Type': 'application/json', ...(extra || {}) };
    if (!llave.startsWith('sb_')) cabeceras.Authorization = 'Bearer ' + llave;   // llave antigua (service_role)
    const r = await fetch(env.SUPABASE_URL.replace(/\/+$/, '') + '/rest/v1/' + ruta, {
        method: metodo,
        headers: cabeceras,
        body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo)
    });
    const texto = await r.text();
    if (!r.ok) throw new Error('Supabase respondió ' + r.status + ': ' + texto.slice(0, 300));
    return texto ? JSON.parse(texto) : null;
}

/* ---------------------------------------------------------------- Tarifas publicadas en index.html */
async function leerTarifas(env) {
    if (cacheTarifas.datos && Date.now() < cacheTarifas.hasta) return cacheTarifas.datos;
    const url = env.SITIO_URL.replace(/\/+$/, '') + '/index.html';
    const r = await fetch(url, { cf: { cacheTtl: 60 } });
    if (!r.ok) throw error(502, 'No pudimos leer las tarifas del hotel.');
    const datos = extraerTarifas(await r.text());
    cacheTarifas = { hasta: Date.now() + MINUTOS_CACHE_TARIFAS * 60000, datos };
    return datos;
}

export function extraerTarifas(html) {
    const bloque = (inicio, fin) => {
        const a = html.indexOf(inicio);
        if (a < 0) return null;
        const b = html.indexOf(fin, a + inicio.length);
        return b < 0 ? null : html.slice(a + inicio.length, b);
    };

    const tarifas = {};
    const bT = bloque('const TARIFAS = {', '};') || '';
    for (const m of bT.matchAll(/(\w+)\s*:\s*\{\s*finde\s*:\s*(\d+)\s*,\s*semana\s*:\s*(\d+)\s*\}/g)) {
        tarifas[m[1]] = { finde: +m[2], semana: +m[3] };
    }

    const unidades = {};
    for (const m of (bloque('const UNIDADES = {', '}') || '').matchAll(/(\w+)\s*:\s*(\d+)/g)) unidades[m[1]] = +m[2];

    const festivos = new Set((bloque('const FESTIVOS = new Set([', ']);') || '').match(/\d{4}-\d{2}-\d{2}/g) || []);

    const promos = {};
    const bP = bloque('const CODIGOS_PROMO = {', '};') || '';
    for (const m of bP.matchAll(/['"]([^'"]+)['"]\s*:\s*\{([^}]*)\}/g)) {
        const desc = /descuento\s*:\s*(\d+(?:\.\d+)?)/.exec(m[2]);
        const act = /activo\s*:\s*(true|false)/.exec(m[2]);
        if (desc) promos[m[1].trim().toUpperCase()] = { descuento: +desc[1], activo: !act || act[1] === 'true' };
    }

    const mascota = /const TARIFA_MASCOTA\s*=\s*(\d+)/.exec(html);
    const anticipo = /const ANTICIPO\s*=\s*(0?\.\d+|1(?:\.0+)?)\s*;/.exec(html);

    if (!Object.keys(tarifas).length || !mascota || !anticipo) throw error(502, 'No pudimos leer las tarifas del hotel.');
    return { tarifas, unidades, festivos, promos, mascota: +mascota[1], anticipo: +anticipo[1] };
}

/* ---------------------------------------------------------------- Utilidades */
function boldConfigurado(env) {
    return !!(env.BOLD_LLAVE_IDENTIDAD && env.BOLD_LLAVE_SECRETA && env.SITIO_URL);
}

function reservasConfiguradas(env) {
    return !!(env.SUPABASE_URL && env.SUPABASE_LLAVE_SECRETA);
}

function origenesPermitidos(env) {
    const lista = String(env.ORIGENES_PERMITIDOS || '').split(',').map(s => s.trim()).filter(Boolean);
    try { lista.push(new URL(env.SITIO_URL).origin); } catch (e) { /* SITIO_URL sin configurar */ }
    return lista;
}

function origenPermitido(origen, env) {
    return !!origen && origenesPermitidos(env).includes(origen);
}

function cabecerasCors(origen, env) {
    const h = { 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Vary': 'Origin' };
    if (origenPermitido(origen, env)) h['Access-Control-Allow-Origin'] = origen;
    return h;
}

function json(cuerpo, status, cabeceras) {
    return new Response(JSON.stringify(cuerpo), {
        status,
        headers: { ...cabeceras, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }
    });
}

function error(status, publico) {
    const e = new Error(publico);
    e.status = status;
    e.publico = publico;
    return e;
}

const leerJson = request => request.json().catch(() => { throw error(400, 'Datos inválidos.'); });

async function sha256(texto) {
    const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto));
    return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}

async function hmacSha256(llave, mensaje) {
    const clave = await crypto.subtle.importKey('raw', llave, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const buf = await crypto.subtle.sign('HMAC', clave, new TextEncoder().encode(mensaje));
    return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}

function aBase64(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

function igualSeguro(a, b) {
    if (a.length !== b.length) return false;
    let diferencia = 0;
    for (let i = 0; i < a.length; i++) diferencia |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diferencia === 0;
}

function aleatorio(n) {
    const letras = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    const bytes = crypto.getRandomValues(new Uint8Array(n));
    return [...bytes].map(b => letras[b % letras.length]).join('');
}

const nuevaOrden = () => 'CAB-' + hoyEnColombia().slice(2).replace(/-/g, '') + '-' + aleatorio(6);
const fecha = s => new Date(s + 'T12:00:00Z');
const sumarDias = (s, n) => { const d = fecha(s); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const hoyEnColombia = () => new Date(Date.now() - 5 * 3600000).toISOString().slice(0, 10);
const corta = s => s.slice(8, 10) + '/' + s.slice(5, 7);
const limpiar = (s, max) => String(s || '').replace(/[<>"'`\\]/g, '').replace(/\s+/g, ' ').trim().slice(0, max);
const entero = (v, min, max) => { const n = Number(v); return Number.isInteger(n) && n >= min && n <= max ? n : null; };
