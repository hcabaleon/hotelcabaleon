-- =====================================================================
--  Reservas de Hotel Cabaleón · base de datos en Supabase
--  ---------------------------------------------------------------------
--  1. Cambia el correo del propietario (última línea de este archivo).
--  2. Supabase → SQL Editor → New query → pega todo → Run.
--  Se puede volver a ejecutar sin perder datos (por ejemplo, para
--  agregar otro correo con acceso al panel).
--  Pasos completos en LEEME-RESERVAS-SUPABASE.txt
-- =====================================================================

-- Una fila por reserva: las de la web (pago con Bold o pago asistido por
-- WhatsApp) y las que el hotel registra a mano desde el panel.
create table if not exists public.reservas (
    id               uuid primary key default gen_random_uuid(),
    orden            text not null unique,              -- CAB-AAMMDD-XXXXXX (web) o MAN-AAMMDD-XXXX (panel)
    creada           timestamptz not null default now(),
    actualizada      timestamptz not null default now(),
    estado           text not null default 'pendiente'
                     check (estado in ('pendiente', 'pagada', 'confirmada', 'cancelada', 'rechazada', 'anulada')),
    canal            text not null default 'manual'
                     check (canal in ('bold', 'whatsapp', 'manual')),
    llegada          date not null,
    salida           date not null,
    noches           integer not null default 1,
    habitaciones     jsonb not null default '{}'::jsonb, -- {"suite": 1, "triple": 2}
    huespedes        integer not null default 1,
    mascotas         integer not null default 0,
    codigo           text,                              -- código promocional aplicado
    modalidad        text check (modalidad in ('anticipo', 'total')),
    total            integer not null default 0,        -- valor de la estadía (COP)
    monto            integer not null default 0,        -- lo que se paga hoy (anticipo o total)
    pagado           integer not null default 0,        -- lo que Bold confirmó
    metodo_pago      text,
    bold_transaccion text,
    nombre           text not null,
    tipo_documento   text,
    documento        text,
    celular          text,
    correo           text,
    notas            text,
    constraint reservas_fechas_validas check (salida > llegada)
);

create index if not exists reservas_por_fechas on public.reservas (llegada, salida);

-- Correos que pueden entrar al panel (en minúsculas)
create table if not exists public.panel_acceso (
    correo text primary key check (correo = lower(correo))
);

-- Fecha de la última modificación de cada reserva
create or replace function public.reservas_tocar() returns trigger
language plpgsql set search_path = '' as $$
begin
    new.actualizada := now();
    return new;
end;
$$;
drop trigger if exists reservas_tocar on public.reservas;
create trigger reservas_tocar before update on public.reservas
    for each row execute function public.reservas_tocar();

-- ¿La persona que inició sesión está en panel_acceso?
create or replace function public.es_del_panel() returns boolean
language sql stable security definer set search_path = '' as $$
    select exists (
        select 1 from public.panel_acceso
        where correo = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$$;
revoke execute on function public.es_del_panel() from public, anon;
grant execute on function public.es_del_panel() to authenticated;

-- Seguridad: las reservas solo las ven y cambian las personas del panel.
-- El servidor de reservas y pagos entra con la llave secreta (service_role).
alter table public.reservas enable row level security;
alter table public.panel_acceso enable row level security;

drop policy if exists "panel ve reservas" on public.reservas;
create policy "panel ve reservas" on public.reservas
    for select to authenticated using ((select public.es_del_panel()));

drop policy if exists "panel crea reservas" on public.reservas;
create policy "panel crea reservas" on public.reservas
    for insert to authenticated with check ((select public.es_del_panel()));

drop policy if exists "panel cambia reservas" on public.reservas;
create policy "panel cambia reservas" on public.reservas
    for update to authenticated
    using ((select public.es_del_panel())) with check ((select public.es_del_panel()));

drop policy if exists "panel borra reservas" on public.reservas;
create policy "panel borra reservas" on public.reservas
    for delete to authenticated using ((select public.es_del_panel()));

drop policy if exists "cada persona ve su acceso" on public.panel_acceso;
create policy "cada persona ve su acceso" on public.panel_acceso
    for select to authenticated using (correo = lower(coalesce(auth.jwt() ->> 'email', '')));

-- Permisos de la API (los proyectos nuevos de Supabase ya no los dan solos)
revoke all on public.reservas, public.panel_acceso from anon;
grant select, insert, update, delete on public.reservas to authenticated;
grant select on public.panel_acceso to authenticated;
grant select, insert, update, delete on public.reservas, public.panel_acceso to service_role;

-- =====================================================================
--  Estadísticas de la página (anónimas)
--  Una fila por evento: visitas, secciones vistas, clics a WhatsApp, pasos
--  de la reserva… No guarda nombres, correos ni direcciones IP: solo un
--  número al azar por navegador (visitante) y por visita (sesion). Las
--  escribe el servidor de reservas; el panel solo ve el resumen.
-- =====================================================================
create table if not exists public.eventos (
    id           bigint generated always as identity primary key,
    creado       timestamptz not null default now(),
    visitante    text not null,
    sesion       text not null,
    nuevo        boolean not null default false,
    tipo         text not null,                 -- visita, seccion, whatsapp, fechas, pago…
    detalle      text,                          -- sección, habitación, tema del asistente…
    valor        integer,                       -- segundos, valor en COP…
    fuente       text,                          -- Google, Instagram, Directo, campaña…
    medio        text,                          -- Buscador, Redes, Pagado, Referido…
    campana      text,                          -- utm_campaign
    referente    text,                          -- sitio desde el que llegó
    entrada      text,                          -- sección por la que entró
    dispositivo  text,
    navegador    text,
    sistema      text,
    idioma       text,
    pais         text,                          -- código del país (CO, US…)
    ciudad       text
);
create index if not exists eventos_por_fecha on public.eventos (creado);
create index if not exists eventos_por_sesion on public.eventos (sesion, creado);

alter table public.eventos enable row level security;
drop policy if exists "panel ve eventos" on public.eventos;
create policy "panel ve eventos" on public.eventos
    for select to authenticated using ((select public.es_del_panel()));
revoke all on public.eventos from anon;
grant select on public.eventos to authenticated;
grant select, insert, delete on public.eventos to service_role;

-- Resumen para el panel (Estadísticas) entre dos fechas, en hora de Colombia.
-- origen (opcional): ver solo las visitas que llegaron de una fuente (Google, Instagram…).
-- La lista de fuentes y los tipos de tráfico siempre incluyen todas las fuentes.
drop function if exists public.estadisticas(date, date);
create or replace function public.estadisticas(desde date, hasta date, origen text default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
    ini       timestamptz := desde::timestamp at time zone 'America/Bogota';
    fin       timestamptz := (hasta + 1)::timestamp at time zone 'America/Bogota';
    ini_antes timestamptz := (desde - (hasta - desde + 1))::timestamp at time zone 'America/Bogota';
    resultado jsonb;
begin
    if not public.es_del_panel() then
        raise exception 'Sin acceso al panel' using errcode = '42501';
    end if;
    if hasta < desde or hasta - desde > 400 then
        raise exception 'Rango de fechas inválido' using errcode = '22023';
    end if;

    with ev_todo as (
        select * from public.eventos where creado >= ini and creado < fin
    ),
    -- Una fila por visita: de dónde llegó, en qué equipo y qué hizo
    ses_base as (
        select
            sesion,
            min(visitante) as visitante,
            bool_or(nuevo) as nuevo,
            min(creado) as inicio,
            least(7200, greatest(extract(epoch from max(creado) - min(creado)),
                                 coalesce(max(valor) filter (where tipo = 'salida'), 0)))::int as duracion,
            coalesce((array_agg(fuente order by creado) filter (where fuente is not null))[1], 'Directo') as fuente,
            (array_agg(medio order by creado) filter (where medio is not null))[1] as medio,
            (array_agg(campana order by creado) filter (where campana is not null))[1] as campana,
            (array_agg(referente order by creado) filter (where referente is not null))[1] as referente,
            (array_agg(entrada order by creado) filter (where entrada is not null))[1] as entrada,
            (array_agg(dispositivo order by creado) filter (where dispositivo is not null))[1] as dispositivo,
            (array_agg(navegador order by creado) filter (where navegador is not null))[1] as navegador,
            (array_agg(sistema order by creado) filter (where sistema is not null))[1] as sistema,
            (array_agg(idioma order by creado) filter (where idioma is not null))[1] as idioma,
            (array_agg(pais order by creado) filter (where pais is not null))[1] as pais,
            (array_agg(ciudad order by creado) filter (where ciudad is not null))[1] as ciudad,
            -- Leer el blog no cuenta como tocar un botón: las lecturas se miden aparte
            count(*) filter (where tipo not in ('visita', 'seccion', 'salida', 'articulo', 'lectura')) as interacciones,
            count(distinct detalle) filter (where tipo = 'seccion') as secciones,
            -- Abrió un artículo del blog (tipo nuevo o, antes de actualizar el servidor, la visita a blog/…)
            bool_or(tipo = 'articulo' or (tipo = 'visita' and detalle like 'blog/_%')) as leyo_blog,
            bool_or(tipo = 'seccion' and detalle = 'reservar') as vio_reservar,
            bool_or(tipo = 'fechas') as eligio_fechas,
            bool_or(tipo = 'habitacion_agregada') as agrego_habitacion,
            bool_or(tipo = 'datos_completos') as completo_datos,
            -- Reservas enviadas: el evento trae "habitaciones|número de orden". Las visitas
            -- anteriores a este cambio no traen el número y cuentan por lo que hicieron.
            array_remove(array_agg(distinct nullif(split_part(detalle, '|', 2), ''))
                         filter (where tipo in ('reserva_whatsapp', 'pago_iniciado')), null) as ordenes,
            bool_or(tipo in ('reserva_whatsapp', 'pago_iniciado') and strpos(coalesce(detalle, ''), '|') = 0) as envio_sin_orden,
            bool_or(tipo = 'pago' and detalle = 'aprobado') as pago_evento,
            bool_or(tipo = 'whatsapp') as escribio,
            bool_or(tipo in ('asistente', 'asistente_tema')) as uso_asistente,
            greatest(coalesce(max(valor) filter (where tipo = 'reserva_whatsapp'), 0),
                     coalesce(max(valor) filter (where tipo = 'pago_iniciado'), 0)) as valor_evento,
            coalesce(max(valor) filter (where tipo = 'pago' and detalle = 'aprobado'), 0) as pagado_evento
        from ev_todo
        group by sesion
    ),
    -- Cómo están hoy las reservas de cada visita: si se eliminó deja de contar,
    -- si se pagó o se confirmó cuenta como pagada y si sigue pendiente, como sin pagar
    ses_reservas as (
        select s.sesion,
               count(*) filter (where r.estado in ('pagada', 'confirmada')) as pagadas,
               count(*) filter (where r.estado = 'pendiente') as pendientes,
               coalesce(sum(r.total) filter (where r.estado in ('pagada', 'confirmada', 'pendiente')), 0) as valor,
               coalesce(sum(r.total) filter (where r.estado in ('pagada', 'confirmada')), 0) as valor_pagadas,
               coalesce(sum(r.pagado) filter (where r.estado in ('pagada', 'confirmada', 'pendiente')), 0) as pagado
        from ses_base s
        cross join lateral unnest(s.ordenes) as o(orden)
        join public.reservas r on r.orden = o.orden
        group by s.sesion
    ),
    -- "Con interés": la página estuvo a la vista 10 segundos o más, o tocaron algún botón
    ses_todo as (
        select b.*,
               (b.duracion >= 10 or b.interacciones > 0) as interes,
               (b.inicio at time zone 'America/Bogota')::date as dia,
               case when cardinality(b.ordenes) > 0 then coalesce(x.pagadas, 0) + coalesce(x.pendientes, 0) > 0
                    else coalesce(b.envio_sin_orden, false) end as confirmo,
               case when cardinality(b.ordenes) > 0 then coalesce(x.pagadas, 0) > 0
                    else b.pago_evento end as pago,
               case when cardinality(b.ordenes) > 0 then coalesce(x.valor, 0) else b.valor_evento end as valor,
               case when cardinality(b.ordenes) > 0 then coalesce(x.valor_pagadas, 0)
                    when b.pago_evento then b.valor_evento else 0 end as valor_pagadas,
               case when cardinality(b.ordenes) > 0 then coalesce(x.pagado, 0) else b.pagado_evento end as pagado
        from ses_base b
        left join ses_reservas x on x.sesion = b.sesion
    ),
    ses as (
        select * from ses_todo where origen is null or fuente = origen
    ),
    ev as (
        select e.* from ev_todo e join ses s on s.sesion = e.sesion
    ),
    -- Una fila por visita y sección vista, con los segundos que estuvo en pantalla
    vista as (
        select sesion, detalle as seccion, sum(valor) as segundos
        from ev where tipo = 'seccion' and detalle is not null
        group by 1, 2
    ),
    dias as (
        select d.t::date as dia from generate_series(desde::timestamp, hasta::timestamp, interval '1 day') as d(t)
    ),
    antes_base as (
        select
            sesion,
            min(visitante) as visitante,
            coalesce((array_agg(fuente order by creado) filter (where fuente is not null))[1], 'Directo') as fuente,
            least(7200, greatest(extract(epoch from max(creado) - min(creado)),
                                 coalesce(max(valor) filter (where tipo = 'salida'), 0)))::int as duracion,
            count(*) filter (where tipo not in ('visita', 'seccion', 'salida', 'articulo', 'lectura')) as interacciones,
            bool_or(tipo = 'articulo' or (tipo = 'visita' and detalle like 'blog/_%')) as leyo_blog,
            bool_or(tipo = 'whatsapp') as escribio,
            array_remove(array_agg(distinct nullif(split_part(detalle, '|', 2), ''))
                         filter (where tipo in ('reserva_whatsapp', 'pago_iniciado')), null) as ordenes,
            bool_or(tipo in ('reserva_whatsapp', 'pago_iniciado') and strpos(coalesce(detalle, ''), '|') = 0) as envio_sin_orden,
            bool_or(tipo = 'pago' and detalle = 'aprobado') as pago_evento,
            greatest(coalesce(max(valor) filter (where tipo = 'reserva_whatsapp'), 0),
                     coalesce(max(valor) filter (where tipo = 'pago_iniciado'), 0)) as valor_evento
        from public.eventos
        where creado >= ini_antes and creado < ini
        group by sesion
    ),
    antes as (
        select a.*,
               case when cardinality(a.ordenes) > 0
                    then exists (select 1 from public.reservas r where r.orden = any(a.ordenes) and r.estado in ('pagada', 'confirmada', 'pendiente'))
                    else coalesce(a.envio_sin_orden, false) end as confirmo,
               case when cardinality(a.ordenes) > 0
                    then exists (select 1 from public.reservas r where r.orden = any(a.ordenes) and r.estado in ('pagada', 'confirmada'))
                    else a.pago_evento end as pago,
               case when cardinality(a.ordenes) > 0
                    then coalesce((select sum(r.total) from public.reservas r where r.orden = any(a.ordenes)
                                   and r.estado in ('pagada', 'confirmada', 'pendiente')), 0)
                    else a.valor_evento end as valor
        from antes_base a
    )
    select jsonb_build_object(
        'desde', desde,
        'hasta', hasta,
        'origen', origen,
        'resumen', (
            select jsonb_build_object(
                'visitas', count(*),
                'visitantes', count(distinct visitante),
                'nuevos', count(distinct visitante) filter (where nuevo),
                'regresaron', count(distinct visitante) filter (where not nuevo),
                'duracion', coalesce(round(avg(duracion)), 0),
                'interes', count(*) filter (where interes),
                'interactuaron', count(*) filter (where interacciones > 0),
                'secciones', coalesce(round(avg(secciones), 1), 0),
                'whatsapp', count(*) filter (where escribio),
                'reservas', count(*) filter (where confirmo),
                'pagadas', count(*) filter (where confirmo and pago),
                'pendientes', count(*) filter (where confirmo and not pago),
                'pagos', count(*) filter (where confirmo and pago),
                'valor', coalesce(sum(valor), 0),
                'valor_pagadas', coalesce(sum(valor_pagadas), 0),
                'pagado', coalesce(sum(pagado), 0),
                'lectores', count(*) filter (where leyo_blog),
                'paginas', (select count(*) from ev where tipo = 'visita'),
                'paginas_blog', (select count(*) from ev where tipo = 'visita' and detalle like 'blog%'))
            from ses),
        'anterior', (
            select jsonb_build_object(
                'visitas', count(*),
                'visitantes', count(distinct visitante),
                'duracion', coalesce(round(avg(duracion)), 0),
                'interes', count(*) filter (where duracion >= 10 or interacciones > 0),
                'whatsapp', count(*) filter (where escribio),
                'reservas', count(*) filter (where confirmo),
                'pagadas', count(*) filter (where confirmo and pago),
                'valor', coalesce(sum(valor), 0),
                'lectores', count(*) filter (where leyo_blog))
            from antes where origen is null or fuente = origen),
        'por_dia', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'dia', dias.dia, 'visitas', coalesce(x.visitas, 0), 'visitantes', coalesce(x.visitantes, 0),
                       'nuevos', coalesce(x.nuevos, 0), 'interes', coalesce(x.interes, 0),
                       'whatsapp', coalesce(x.whatsapp, 0), 'reservas', coalesce(x.reservas, 0),
                       'pagadas', coalesce(x.pagadas, 0), 'pendientes', coalesce(x.reservas, 0) - coalesce(x.pagadas, 0),
                       'valor', coalesce(x.valor, 0), 'lectores', coalesce(x.lectores, 0)) order by dias.dia), '[]'::jsonb)
            from dias
            left join (
                select dia, count(*) as visitas, count(distinct visitante) as visitantes,
                       count(distinct visitante) filter (where nuevo) as nuevos,
                       count(*) filter (where interes) as interes,
                       count(*) filter (where escribio) as whatsapp,
                       count(*) filter (where confirmo) as reservas,
                       count(*) filter (where confirmo and pago) as pagadas,
                       sum(valor) as valor,
                       count(*) filter (where leyo_blog) as lectores
                from ses group by dia) x on x.dia = dias.dia),
        -- Todas las fuentes, cada una con sus números y su visita día a día
        'fuentes', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'nombre', f.fuente, 'medio', f.medio, 'visitas', f.visitas, 'visitantes', f.visitantes,
                       'nuevos', f.nuevos, 'duracion', f.duracion, 'interes', f.interes, 'secciones', f.secciones,
                       'whatsapp', f.whatsapp, 'reservas', f.reservas, 'pagadas', f.pagos, 'pendientes', f.reservas - f.pagos,
                       'pagos', f.pagos, 'valor', f.valor, 'valor_pagadas', f.valor_pagadas, 'lectores', f.lectores,
                       'serie', sr.serie) order by f.visitas desc, f.fuente), '[]'::jsonb)
            from (select fuente, mode() within group (order by medio) as medio,
                         count(*) as visitas, count(distinct visitante) as visitantes,
                         count(distinct visitante) filter (where nuevo) as nuevos,
                         round(avg(duracion)) as duracion, count(*) filter (where interes) as interes,
                         round(avg(secciones), 1) as secciones,
                         count(*) filter (where escribio) as whatsapp, count(*) filter (where confirmo) as reservas,
                         count(*) filter (where confirmo and pago) as pagos, coalesce(sum(valor), 0) as valor,
                         coalesce(sum(valor_pagadas), 0) as valor_pagadas,
                         count(*) filter (where leyo_blog) as lectores
                  from ses_todo group by fuente) f
            cross join lateral (
                select jsonb_agg(coalesce(c.n, 0) order by dias.dia) as serie
                from dias left join (select dia, count(*) as n from ses_todo s2 where s2.fuente = f.fuente group by dia) c
                       on c.dia = dias.dia) sr),
        'medios', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n, 'reservas', r, 'pagadas', p, 'valor', v)
                                      order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(medio, 'Directo') as nombre, count(*) as n, count(*) filter (where confirmo) as r,
                         count(*) filter (where confirmo and pago) as p, coalesce(sum(valor), 0) as v
                  from ses_todo group by 1) t),
        'referentes', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', referente, 'visitas', n, 'reservas', r)
                                      order by n desc, referente), '[]'::jsonb)
            from (select referente, count(*) as n, count(*) filter (where confirmo) as r from ses
                  where referente is not null group by 1 order by 2 desc, 1 limit 12) t),
        'campanas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', campana, 'fuente', fuente, 'medio', medio,
                                                         'visitas', n, 'whatsapp', w, 'reservas', r, 'pagadas', p, 'valor', v)
                                      order by n desc, campana), '[]'::jsonb)
            from (select campana, fuente, medio, count(*) as n, count(*) filter (where escribio) as w,
                         count(*) filter (where confirmo) as r, count(*) filter (where confirmo and pago) as p,
                         coalesce(sum(valor), 0) as v
                  from ses where campana is not null group by 1, 2, 3 order by 4 desc, 1 limit 20) t),
        'dispositivos', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n, 'interes', i,
                                                         'reservas', r, 'duracion', du) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(dispositivo, 'Otro') as nombre, count(*) as n, count(*) filter (where interes) as i,
                         count(*) filter (where confirmo) as r, round(avg(duracion)) as du
                  from ses group by 1) t),
        'navegadores', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(navegador, 'Otro') as nombre, count(*) as n from ses
                  group by 1 order by 2 desc, 1 limit 6) t),
        'sistemas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(sistema, 'Otro') as nombre, count(*) as n from ses
                  group by 1 order by 2 desc, 1 limit 6) t),
        'paises', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', pais, 'visitas', n, 'reservas', r) order by n desc, pais), '[]'::jsonb)
            from (select pais, count(*) as n, count(*) filter (where confirmo) as r from ses where pais is not null
                  group by 1 order by 2 desc, 1 limit 8) t),
        'ciudades', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', ciudad, 'pais', pais, 'visitas', n, 'reservas', r)
                                      order by n desc, ciudad), '[]'::jsonb)
            from (select ciudad, pais, count(*) as n, count(*) filter (where confirmo) as r from ses
                  where ciudad is not null group by 1, 2 order by 3 desc, 1 limit 10) t),
        'idiomas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n) order by n desc, nombre), '[]'::jsonb)
            from (select lower(split_part(idioma, '-', 1)) as nombre, count(*) as n from ses
                  where coalesce(idioma, '') <> '' group by 1 order by 2 desc, 1 limit 6) t),
        'entradas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', entrada, 'visitas', n) order by n desc, entrada), '[]'::jsonb)
            from (select entrada, count(*) as n from ses where entrada is not null
                  group by 1 order by 2 desc, 1 limit 8) t),
        -- Cada sección: cuántas visitas la vieron, cuánto tiempo, qué hicieron después y de dónde venían
        'secciones', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'nombre', v.seccion, 'visitas', v.visitas, 'segundos', v.segundos,
                       'whatsapp', v.whatsapp, 'reservas', v.reservas, 'pagadas', v.pagadas,
                       'entradas', coalesce(en.n, 0), 'clics', coalesce(cl.n, 0),
                       'serie', sr.serie, 'fuentes', sf.fuentes) order by v.visitas desc, v.seccion), '[]'::jsonb)
            from (select w.seccion, count(*) as visitas, round(avg(w.segundos)) as segundos,
                         count(*) filter (where s.escribio) as whatsapp, count(*) filter (where s.confirmo) as reservas,
                         count(*) filter (where s.confirmo and s.pago) as pagadas
                  from vista w join ses s on s.sesion = w.sesion group by 1) v
            left join (select entrada, count(*) as n from ses group by 1) en on en.entrada = v.seccion
            left join (select detalle, count(*) as n from ev
                       where tipo in ('whatsapp', 'llamada', 'correo', 'como_llegar') group by 1) cl on cl.detalle = v.seccion
            cross join lateral (
                select jsonb_agg(coalesce(c.n, 0) order by dias.dia) as serie
                from dias left join (select (e.creado at time zone 'America/Bogota')::date as dia, count(distinct e.sesion) as n
                                     from ev e where e.tipo = 'seccion' and e.detalle = v.seccion group by 1) c
                       on c.dia = dias.dia) sr
            cross join lateral (
                select coalesce(jsonb_agg(jsonb_build_object('nombre', x.fuente, 'visitas', x.n)
                                          order by x.n desc, x.fuente), '[]'::jsonb) as fuentes
                from (select s.fuente, count(*) as n from vista w join ses s on s.sesion = w.sesion
                      where w.seccion = v.seccion group by 1 order by 2 desc, 1 limit 5) x) sf),
        -- Cuántas secciones recorre cada visita
        'profundidad', (
            select jsonb_agg(jsonb_build_object('nombre', b.nombre, 'visitas', x.n) order by b.orden)
            from (values (1, '1 sección o menos', 0, 1), (2, '2 a 3 secciones', 2, 3), (3, '4 a 6 secciones', 4, 6),
                         (4, '7 a 10 secciones', 7, 10), (5, 'Más de 10', 11, 1000)) as b(orden, nombre, minimo, maximo)
            cross join lateral (select count(*) as n from ses where secciones between b.minimo and b.maximo) x),
        -- Cuántas veces volvió cada visitante en el período
        'recurrencia', (
            select jsonb_agg(jsonb_build_object('nombre', b.nombre, 'visitantes', x.n) order by b.orden)
            from (values (1, '1 visita', 1, 1), (2, '2 visitas', 2, 2), (3, '3 a 5 visitas', 3, 5),
                         (4, '6 o más', 6, 100000)) as b(orden, nombre, minimo, maximo)
            cross join lateral (select count(*) as n from (select visitante, count(*) as k from ses group by 1) v
                                where v.k between b.minimo and b.maximo) x),
        -- Día de la semana (lunes a domingo) por hora del día
        'mapa_calor', (
            select jsonb_agg(t.fila order by t.d)
            from (select d.d, jsonb_agg(coalesce(x.n, 0) order by h.h) as fila
                  from generate_series(1, 7) as d(d) cross join generate_series(0, 23) as h(h)
                  left join (select extract(isodow from inicio at time zone 'America/Bogota')::int as dia,
                                    extract(hour from inicio at time zone 'America/Bogota')::int as hora, count(*) as n
                             from ses group by 1, 2) x on x.dia = d.d and x.hora = h.h
                  group by d.d) t),
        'interacciones', (
            select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total, 'visitas', n) order by total desc, tipo), '[]'::jsonb)
            from (select tipo, count(*) as total, count(distinct sesion) as n from ev
                  where tipo not in ('visita', 'seccion', 'salida', 'articulo', 'lectura') group by 1) t),
        'whatsapp_desde', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'total', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(detalle, 'otro') as nombre, count(*) as n from ev
                  where tipo = 'whatsapp' group by 1 order by 2 desc, 1 limit 8) t),
        'contactos', (
            select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'lugar', lugar, 'total', n) order by n desc, tipo, lugar), '[]'::jsonb)
            from (select tipo, coalesce(detalle, 'otro') as lugar, count(*) as n from ev
                  where tipo in ('whatsapp', 'llamada', 'correo', 'como_llegar')
                  group by 1, 2 order by 3 desc, 1, 2 limit 40) t),
        'habitaciones', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', k, 'fichas', f, 'agregadas', a, 'reservadas', r)
                                      order by f + a + r desc, k), '[]'::jsonb)
            from (select k, count(*) filter (where tipo = 'ficha_habitacion') as f,
                         count(*) filter (where tipo = 'habitacion_agregada') as a,
                         count(*) filter (where tipo in ('reserva_whatsapp', 'pago_iniciado')) as r
                  from (select e.tipo, unnest(string_to_array(split_part(e.detalle, '|', 1), '+')) as k from ev e
                        where e.tipo in ('ficha_habitacion', 'habitacion_agregada', 'reserva_whatsapp', 'pago_iniciado')
                          and e.detalle is not null
                          and (e.tipo not in ('reserva_whatsapp', 'pago_iniciado') or strpos(e.detalle, '|') = 0
                               or exists (select 1 from public.reservas r where r.orden = split_part(e.detalle, '|', 2)
                                          and r.estado in ('pagada', 'confirmada', 'pendiente')))) u
                  where k <> '' group by k) t),
        'temas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'total', n) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) as n from ev where tipo = 'asistente_tema' and detalle is not null
                  group by 1 order by 2 desc, 1 limit 14) t),
        'asistente', (
            select jsonb_build_object(
                'aperturas', (select count(*) from ev where tipo = 'asistente'),
                'preguntas', (select count(*) from ev where tipo = 'asistente_tema'),
                'sin_respuesta', (select count(*) from ev where tipo = 'asistente_tema' and detalle = 'sin_respuesta'),
                'visitas', count(*) filter (where uso_asistente),
                'whatsapp', count(*) filter (where uso_asistente and escribio),
                'reservas', count(*) filter (where uso_asistente and confirmo),
                'pagadas', count(*) filter (where uso_asistente and confirmo and pago))
            from ses),
        'planes', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'total', n, 'visitas', v) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) as n, count(distinct sesion) as v from ev
                  where tipo = 'plan' and detalle is not null group by 1) t),
        'documentos', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'total', n, 'visitas', v) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) as n, count(distinct sesion) as v from ev
                  where tipo = 'documento' and detalle is not null group by 1) t),
        'redes', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'total', n, 'visitas', v) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) as n, count(distinct sesion) as v from ev
                  where tipo = 'red_social' and detalle is not null group by 1) t),
        'galeria', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'total', n, 'visitas', v) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(detalle, 'otra') as nombre, count(*) as n, count(distinct sesion) as v from ev
                  where tipo = 'galeria' group by 1) t),
        'pedidos', (
            select jsonb_build_object(
                'pedidos', count(*), 'visitas', count(distinct sesion),
                'platos', coalesce(sum(case when detalle ~ '^[0-9]{1,4}$' then detalle::int else 0 end), 0),
                'valor', coalesce(sum(valor), 0))
            from ev where tipo = 'pedido_mangole'),
        'horas', (
            select jsonb_agg(coalesce(x.n, 0) order by h)
            from generate_series(0, 23) as h
            left join (select extract(hour from inicio at time zone 'America/Bogota')::int as hora, count(*) as n
                       from ses group by 1) x on x.hora = h),
        'dias_semana', (
            select jsonb_agg(coalesce(x.n, 0) order by d)
            from generate_series(1, 7) as d
            left join (select extract(isodow from inicio at time zone 'America/Bogota')::int as dia, count(*) as n
                       from ses group by 1) x on x.dia = d),
        -- Blog: qué artículos leen, cuánto tiempo, hasta dónde, de dónde llegan los lectores y qué hacen después.
        -- Las páginas del blog envían: visita (detalle "blog/<artículo>" o "blog"), articulo (al abrir y, al salir,
        -- con los segundos de lectura), lectura (25, 50, 75 o 100 % del texto), blog_clic ("<artículo>|<destino>")
        -- y los contactos con el lugar "blog:<artículo>". La portada envía blog ("<artículo>" o "todos") al tocar una tarjeta.
        'blog', (
            with lect as (     -- una fila por visita y artículo
                select x.sesion, x.articulo,
                       count(*) filter (where x.es_vista) as vistas,
                       coalesce(sum(x.segundos), 0) as segundos,
                       coalesce(max(x.avance), 0) as avance,
                       min(x.creado) as inicio
                from (select e.sesion, e.creado,
                             case when e.tipo = 'visita' then substr(e.detalle, 6) else e.detalle end as articulo,
                             e.tipo = 'visita' as es_vista,
                             case when e.tipo = 'articulo' then e.valor end as segundos,
                             case when e.tipo = 'lectura' then e.valor end as avance
                      from ev e
                      where (e.tipo = 'visita' and e.detalle like 'blog/_%')
                         or (e.tipo in ('articulo', 'lectura') and e.detalle is not null)) x
                where x.articulo ~ '^[a-z0-9-]{1,60}$'
                group by 1, 2
            ),
            lect_ses as (      -- cada lectura con lo que hizo esa visita
                select l.*, s.fuente, s.escribio, s.confirmo, s.pago, s.valor
                from lect l join ses s on s.sesion = l.sesion
            ),
            lector as (        -- una fila por visita que leyó el blog
                select sesion, count(*) as articulos, sum(segundos) as segundos, max(avance) as avance, min(inicio) as inicio,
                       min(fuente) as fuente, bool_or(escribio) as escribio, bool_or(confirmo) as confirmo,
                       bool_or(confirmo and pago) as pago, max(valor) as valor
                from lect_ses group by sesion
            ),
            clics as (
                select split_part(detalle, '|', 1) as articulo, split_part(detalle, '|', 2) as destino,
                       count(*) as n, count(distinct sesion) as v
                from ev where tipo = 'blog_clic' and strpos(coalesce(detalle, ''), '|') > 0 group by 1, 2
            ),
            portada as (
                select detalle as articulo, count(*) as n, count(distinct sesion) as v
                from ev where tipo = 'blog' and detalle is not null group by 1
            ),
            contacto as (
                select substr(detalle, 6) as articulo, tipo, count(*) as n
                from ev where tipo in ('whatsapp', 'llamada', 'correo', 'como_llegar') and detalle like 'blog:_%' group by 1, 2
            )
            select jsonb_build_object(
                'lectores', (select count(*) from lector),
                'lecturas', (select coalesce(sum(greatest(vistas, 1)), 0) from lect),
                'articulos_por_lector', (select coalesce(round(avg(articulos), 1), 0) from lector),
                'segundos', (select coalesce(round(avg(segundos) filter (where segundos > 0)), 0) from lect),
                'avance', (select jsonb_build_object('medidos', count(*) filter (where avance > 0),
                                                     'p25', count(*) filter (where avance >= 25), 'p50', count(*) filter (where avance >= 50),
                                                     'p75', count(*) filter (where avance >= 75), 'p100', count(*) filter (where avance >= 100))
                           from lect),
                'entradas', (select count(*) from ses where entrada like 'blog%'),
                'listado', (select count(*) from ev where tipo = 'visita' and detalle = 'blog'),
                'desde_portada', (select coalesce(sum(n), 0) from portada where articulo <> 'todos'),
                'portada_todos', (select coalesce(sum(n), 0) from portada where articulo = 'todos'),
                'whatsapp', (select count(*) from lector where escribio),
                'reservas', (select count(*) from lector where confirmo),
                'pagadas', (select count(*) from lector where pago),
                'valor', (select coalesce(sum(valor) filter (where confirmo), 0) from lector),
                'serie', (select jsonb_agg(coalesce(c.n, 0) order by dias.dia)
                          from dias left join (select (inicio at time zone 'America/Bogota')::date as dia, count(*) as n
                                               from lector group by 1) c on c.dia = dias.dia),
                'fuentes', (select coalesce(jsonb_agg(jsonb_build_object('nombre', fuente, 'visitas', n, 'reservas', r)
                                                      order by n desc, fuente), '[]'::jsonb)
                            from (select fuente, count(*) as n, count(*) filter (where confirmo) as r from lector
                                  group by 1 order by 2 desc, 1 limit 8) t),
                'destinos', (select coalesce(jsonb_agg(jsonb_build_object('nombre', destino, 'total', n, 'visitas', v)
                                                       order by n desc, destino), '[]'::jsonb)
                             from (select destino, sum(n) as n, sum(v) as v from clics group by 1) t),
                'articulos', (
                    select coalesce(jsonb_agg(jsonb_build_object(
                               'nombre', a.articulo, 'lectores', a.lectores, 'vistas', a.vistas, 'segundos', a.segundos,
                               'medidos', a.medidos, 'mitad', a.mitad, 'final', a.final,
                               'entradas', coalesce(en.n, 0), 'desde_portada', coalesce(po.n, 0),
                               'whatsapp', a.whatsapp, 'reservas', a.reservas, 'pagadas', a.pagadas, 'valor', a.valor,
                               'contactos', coalesce(co.lista, '[]'::jsonb), 'clics', coalesce(cl.lista, '[]'::jsonb),
                               'serie', sr.serie, 'fuentes', sf.fuentes) order by a.lectores desc, a.articulo), '[]'::jsonb)
                    from (select articulo, count(*) as lectores, sum(greatest(vistas, 1)) as vistas,
                                 round(avg(segundos) filter (where segundos > 0)) as segundos,
                                 count(*) filter (where avance > 0) as medidos, count(*) filter (where avance >= 50) as mitad,
                                 count(*) filter (where avance >= 100) as final,
                                 count(*) filter (where escribio) as whatsapp, count(*) filter (where confirmo) as reservas,
                                 count(*) filter (where confirmo and pago) as pagadas,
                                 coalesce(sum(valor) filter (where confirmo), 0) as valor
                          from lect_ses group by 1) a
                    left join (select substr(entrada, 6) as articulo, count(*) as n from ses
                               where entrada like 'blog/_%' group by 1) en on en.articulo = a.articulo
                    left join portada po on po.articulo = a.articulo
                    left join (select articulo, jsonb_agg(jsonb_build_object('tipo', tipo, 'total', n) order by n desc, tipo) as lista
                               from contacto group by 1) co on co.articulo = a.articulo
                    left join (select articulo, jsonb_agg(jsonb_build_object('nombre', destino, 'total', n) order by n desc, destino) as lista
                               from clics group by 1) cl on cl.articulo = a.articulo
                    cross join lateral (
                        select jsonb_agg(coalesce(c.n, 0) order by dias.dia) as serie
                        from dias left join (select (l2.inicio at time zone 'America/Bogota')::date as dia, count(*) as n
                                             from lect l2 where l2.articulo = a.articulo group by 1) c on c.dia = dias.dia) sr
                    cross join lateral (
                        select coalesce(jsonb_agg(jsonb_build_object('nombre', x.fuente, 'visitas', x.n) order by x.n desc, x.fuente), '[]'::jsonb) as fuentes
                        from (select l3.fuente, count(*) as n from lect_ses l3 where l3.articulo = a.articulo
                              group by 1 order by 2 desc, 1 limit 5) x) sf)
            )
        ),
        'embudo', (
            select jsonb_build_array(
                jsonb_build_object('paso', 'visita', 'visitas', count(*)),
                jsonb_build_object('paso', 'reservar', 'visitas', count(*) filter (where vio_reservar)),
                jsonb_build_object('paso', 'fechas', 'visitas', count(*) filter (where eligio_fechas)),
                jsonb_build_object('paso', 'habitacion', 'visitas', count(*) filter (where agrego_habitacion)),
                jsonb_build_object('paso', 'datos', 'visitas', count(*) filter (where completo_datos)),
                jsonb_build_object('paso', 'confirmo', 'visitas', count(*) filter (where confirmo)),
                jsonb_build_object('paso', 'pago', 'visitas', count(*) filter (where confirmo and pago)))
            from ses)
    ) into resultado;

    return resultado;
end;
$$;
revoke execute on function public.estadisticas(date, date, text) from public, anon;
grant execute on function public.estadisticas(date, date, text) to authenticated;

-- Que la API de Supabase vea la función nueva enseguida
notify pgrst, 'reload schema';

-- Correo del propietario: cámbialo por el real. Para dar acceso a otra
-- persona, copia la línea con su correo (en minúsculas) y vuelve a ejecutar.
insert into public.panel_acceso (correo) values ('hcabaleon@gmail.com') on conflict do nothing;
