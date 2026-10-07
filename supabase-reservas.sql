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

drop policy if exists "cada persona ve su acceso" on public.panel_acceso;
create policy "cada persona ve su acceso" on public.panel_acceso
    for select to authenticated using (correo = lower(coalesce(auth.jwt() ->> 'email', '')));

-- Permisos de la API (los proyectos nuevos de Supabase ya no los dan solos)
revoke all on public.reservas, public.panel_acceso from anon;
grant select, insert, update on public.reservas to authenticated;
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

-- Resumen para el panel (Estadísticas) entre dos fechas, en hora de Colombia
create or replace function public.estadisticas(desde date, hasta date)
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

    with ev as (
        select * from public.eventos where creado >= ini and creado < fin
    ),
    ses as (
        select
            sesion,
            min(visitante) as visitante,
            bool_or(nuevo) as nuevo,
            min(creado) as inicio,
            least(7200, greatest(extract(epoch from max(creado) - min(creado)),
                                 coalesce(max(valor) filter (where tipo = 'salida'), 0)))::int as duracion,
            (array_agg(fuente order by creado) filter (where fuente is not null))[1] as fuente,
            (array_agg(medio order by creado) filter (where medio is not null))[1] as medio,
            (array_agg(campana order by creado) filter (where campana is not null))[1] as campana,
            (array_agg(referente order by creado) filter (where referente is not null))[1] as referente,
            (array_agg(entrada order by creado) filter (where entrada is not null))[1] as entrada,
            (array_agg(dispositivo order by creado) filter (where dispositivo is not null))[1] as dispositivo,
            (array_agg(navegador order by creado) filter (where navegador is not null))[1] as navegador,
            (array_agg(sistema order by creado) filter (where sistema is not null))[1] as sistema,
            (array_agg(pais order by creado) filter (where pais is not null))[1] as pais,
            (array_agg(ciudad order by creado) filter (where ciudad is not null))[1] as ciudad,
            count(*) filter (where tipo not in ('visita', 'seccion', 'salida')) as interacciones,
            bool_or(tipo = 'seccion' and detalle = 'reservar') as vio_reservar,
            bool_or(tipo = 'fechas') as eligio_fechas,
            bool_or(tipo = 'habitacion_agregada') as agrego_habitacion,
            bool_or(tipo = 'datos_completos') as completo_datos,
            bool_or(tipo in ('reserva_whatsapp', 'pago_iniciado')) as confirmo,
            bool_or(tipo = 'pago' and detalle = 'aprobado') as pago,
            bool_or(tipo = 'whatsapp') as escribio
        from ev
        group by sesion
    )
    select jsonb_build_object(
        'desde', desde,
        'hasta', hasta,
        'resumen', (
            select jsonb_build_object(
                'visitas', count(*),
                'visitantes', count(distinct visitante),
                'nuevos', count(distinct visitante) filter (where nuevo),
                'duracion', coalesce(round(avg(duracion)), 0),
                'interactuaron', count(*) filter (where interacciones > 0),
                'whatsapp', count(*) filter (where escribio),
                'reservas', count(*) filter (where confirmo),
                'pagos', count(*) filter (where pago),
                'paginas', (select count(*) from ev where tipo = 'visita'))
            from ses),
        'anterior', (
            select jsonb_build_object(
                'visitas', count(distinct sesion),
                'visitantes', count(distinct visitante),
                'whatsapp', count(distinct sesion) filter (where tipo = 'whatsapp'),
                'reservas', count(distinct sesion) filter (where tipo in ('reserva_whatsapp', 'pago_iniciado')))
            from public.eventos where creado >= ini_antes and creado < ini),
        'por_dia', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'dia', d.t::date, 'visitas', coalesce(x.visitas, 0), 'visitantes', coalesce(x.visitantes, 0),
                       'whatsapp', coalesce(x.whatsapp, 0), 'reservas', coalesce(x.reservas, 0)) order by d.t), '[]'::jsonb)
            from generate_series(desde::timestamp, hasta::timestamp, interval '1 day') as d(t)
            left join (
                select (inicio at time zone 'America/Bogota')::date as dia, count(*) as visitas,
                       count(distinct visitante) as visitantes, count(*) filter (where escribio) as whatsapp,
                       count(*) filter (where confirmo) as reservas
                from ses group by 1) x on x.dia = d.t::date),
        'fuentes', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n, 'whatsapp', w, 'reservas', r)
                                      order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(fuente, 'Directo') as nombre, count(*) as n,
                         count(*) filter (where escribio) as w, count(*) filter (where confirmo) as r
                  from ses group by 1) t),
        'referentes', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', referente, 'visitas', n) order by n desc, referente), '[]'::jsonb)
            from (select referente, count(*) as n from ses where referente is not null
                  group by 1 order by 2 desc, 1 limit 10) t),
        'campanas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', campana, 'fuente', fuente, 'medio', medio,
                                                         'visitas', n, 'reservas', r) order by n desc, campana), '[]'::jsonb)
            from (select campana, fuente, medio, count(*) as n, count(*) filter (where confirmo) as r
                  from ses where campana is not null group by 1, 2, 3 order by 4 desc, 1 limit 10) t),
        'dispositivos', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(dispositivo, 'Otro') as nombre, count(*) as n from ses group by 1) t),
        'navegadores', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(navegador, 'Otro') as nombre, count(*) as n from ses
                  group by 1 order by 2 desc, 1 limit 6) t),
        'sistemas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'visitas', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(sistema, 'Otro') as nombre, count(*) as n from ses
                  group by 1 order by 2 desc, 1 limit 6) t),
        'paises', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', pais, 'visitas', n) order by n desc, pais), '[]'::jsonb)
            from (select pais, count(*) as n from ses where pais is not null
                  group by 1 order by 2 desc, 1 limit 8) t),
        'ciudades', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', ciudad, 'pais', pais, 'visitas', n) order by n desc, ciudad), '[]'::jsonb)
            from (select ciudad, pais, count(*) as n from ses where ciudad is not null
                  group by 1, 2 order by 3 desc, 1 limit 8) t),
        'entradas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', entrada, 'visitas', n) order by n desc, entrada), '[]'::jsonb)
            from (select entrada, count(*) as n from ses where entrada is not null
                  group by 1 order by 2 desc, 1 limit 8) t),
        'secciones', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'visitas', n) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(distinct sesion) as n from ev
                  where tipo = 'seccion' and detalle is not null group by 1) t),
        'interacciones', (
            select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total, 'visitas', n) order by total desc, tipo), '[]'::jsonb)
            from (select tipo, count(*) as total, count(distinct sesion) as n from ev
                  where tipo not in ('visita', 'seccion', 'salida') group by 1) t),
        'whatsapp_desde', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'total', n) order by n desc, nombre), '[]'::jsonb)
            from (select coalesce(detalle, 'otro') as nombre, count(*) as n from ev
                  where tipo = 'whatsapp' group by 1 order by 2 desc, 1 limit 8) t),
        'habitaciones', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'fichas', fichas, 'agregadas', agregadas)
                                      order by fichas + agregadas desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) filter (where tipo = 'ficha_habitacion') as fichas,
                         count(*) filter (where tipo = 'habitacion_agregada') as agregadas
                  from ev where tipo in ('ficha_habitacion', 'habitacion_agregada') and detalle is not null group by 1) t),
        'temas', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'total', n) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) as n from ev where tipo = 'asistente_tema' and detalle is not null
                  group by 1 order by 2 desc, 1 limit 10) t),
        'planes', (
            select coalesce(jsonb_agg(jsonb_build_object('nombre', detalle, 'total', n) order by n desc, detalle), '[]'::jsonb)
            from (select detalle, count(*) as n from ev where tipo = 'plan' and detalle is not null group by 1) t),
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
        'embudo', (
            select jsonb_build_array(
                jsonb_build_object('paso', 'visita', 'visitas', count(*)),
                jsonb_build_object('paso', 'reservar', 'visitas', count(*) filter (where vio_reservar)),
                jsonb_build_object('paso', 'fechas', 'visitas', count(*) filter (where eligio_fechas)),
                jsonb_build_object('paso', 'habitacion', 'visitas', count(*) filter (where agrego_habitacion)),
                jsonb_build_object('paso', 'datos', 'visitas', count(*) filter (where completo_datos)),
                jsonb_build_object('paso', 'confirmo', 'visitas', count(*) filter (where confirmo)))
            from ses)
    ) into resultado;

    return resultado;
end;
$$;
revoke execute on function public.estadisticas(date, date) from public, anon;
grant execute on function public.estadisticas(date, date) to authenticated;

-- Correo del propietario: cámbialo por el real. Para dar acceso a otra
-- persona, copia la línea con su correo (en minúsculas) y vuelve a ejecutar.
insert into public.panel_acceso (correo) values ('propietario@hotelcabaleon.com') on conflict do nothing;
