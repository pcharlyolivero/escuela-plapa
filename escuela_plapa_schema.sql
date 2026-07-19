-- ═══════════════════════════════════════════════════════════════════
-- ESCUELA PLAPA · SCHEMA SUPABASE
-- ═══════════════════════════════════════════════════════════════════
-- Pegar TODO este archivo en:
--   Supabase Dashboard → SQL Editor → New query → Run
--
-- Se puede ejecutar de una sola vez. Si algo falla en medio,
-- corregí y volvé a correr — todos los CREATE usan IF NOT EXISTS
-- o son idempotentes.
--
-- Este schema incluye:
--   1. Tabla perfiles (extiende auth.users)
--   2. Tabla foro_comentarios (con hilos y moderación)
--   3. Tabla foro_reacciones (emojis)
--   4. Tabla evaluaciones_itinerario (revisión de vida VJA)
--   5. Triggers de autopoblado y timestamp
--   6. Políticas RLS (Row-Level Security)
--   7. Funciones RPC usadas por el frontend
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. TABLA PERFILES
-- ───────────────────────────────────────────────────────────────────
-- Cada fila corresponde 1:1 con una fila en auth.users.
-- Se crea automáticamente al hacer signup (ver trigger más abajo).

create table if not exists public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null default '',
  pais text not null default '',
  comunidad text,
  rol text,
  es_moderador boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.perfiles is 'Datos públicos y pastorales de cada participante de la Escuela PLAPA';
comment on column public.perfiles.es_moderador is 'Solo moderadores aprueban comentarios y ven evaluaciones compartidas';


-- ───────────────────────────────────────────────────────────────────
-- 2. TABLA FORO_COMENTARIOS
-- ───────────────────────────────────────────────────────────────────
-- Comentarios y respuestas del "Muro del camino".
-- parent_id null = comentario raíz; parent_id != null = respuesta a otro.

create table if not exists public.foro_comentarios (
  id uuid primary key default gen_random_uuid(),
  itinerario_id text not null,
  parent_id uuid references public.foro_comentarios(id) on delete cascade,
  usuario_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  autor_nombre text not null default '',   -- autopoblado por trigger
  pais text default '',                     -- autopoblado por trigger
  modulo int check (modulo between 1 and 4),
  texto text not null check (length(texto) between 3 and 4000),
  estado text not null default 'pendiente' check (estado in ('pendiente','publicado','rechazado')),
  moderado_por uuid references auth.users(id),
  moderado_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_foro_itinerario_estado
  on public.foro_comentarios(itinerario_id, estado, created_at);
create index if not exists idx_foro_parent
  on public.foro_comentarios(parent_id);
create index if not exists idx_foro_usuario
  on public.foro_comentarios(usuario_id);


-- ───────────────────────────────────────────────────────────────────
-- 3. TABLA FORO_REACCIONES
-- ───────────────────────────────────────────────────────────────────
-- Un usuario puede tener a lo sumo una reacción de cada emoji por
-- comentario (PK compuesta).

create table if not exists public.foro_reacciones (
  comentario_id uuid not null references public.foro_comentarios(id) on delete cascade,
  usuario_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  emoji text not null check (emoji in ('🙏','❤️','💡','🕊️')),
  created_at timestamptz not null default now(),
  primary key (comentario_id, usuario_id, emoji)
);

create index if not exists idx_reacciones_comentario
  on public.foro_reacciones(comentario_id);


-- ───────────────────────────────────────────────────────────────────
-- 4. TABLA EVALUACIONES_ITINERARIO
-- ───────────────────────────────────────────────────────────────────
-- Una evaluación (revisión de vida VJA) por usuario × itinerario.
-- El UNIQUE permite el upsert (Prefer: resolution=merge-duplicates).

create table if not exists public.evaluaciones_itinerario (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  itinerario_id text not null,
  respuestas jsonb not null default '{}'::jsonb,
  compartir_con_equipo boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (usuario_id, itinerario_id)
);

create index if not exists idx_eval_itin_compartidas
  on public.evaluaciones_itinerario(itinerario_id)
  where compartir_con_equipo = true;


-- ───────────────────────────────────────────────────────────────────
-- 5. TRIGGERS
-- ───────────────────────────────────────────────────────────────────

-- Al crear un usuario en auth.users, crear su perfil con los
-- datos que vinieron en raw_user_meta_data (nombre, país, etc.)
create or replace function public.crear_perfil_desde_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfiles (id, nombre, pais, comunidad, rol)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    coalesce(new.raw_user_meta_data->>'pais', ''),
    nullif(new.raw_user_meta_data->>'comunidad', ''),
    nullif(new.raw_user_meta_data->>'rol', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.crear_perfil_desde_signup();


-- Al insertar un comentario, autopoblar autor_nombre y pais desde
-- el perfil del usuario autenticado. Esto evita que el cliente
-- pueda spoofear el nombre.
create or replace function public.completar_comentario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
begin
  select nombre, pais into p from public.perfiles where id = auth.uid();
  new.autor_nombre := coalesce(p.nombre, '');
  new.pais := coalesce(p.pais, '');
  new.estado := 'pendiente';   -- fuerza estado pendiente al crear
  new.moderado_por := null;
  new.moderado_at := null;
  return new;
end;
$$;

drop trigger if exists antes_insertar_comentario on public.foro_comentarios;
create trigger antes_insertar_comentario
before insert on public.foro_comentarios
for each row execute function public.completar_comentario();


-- Cuando un moderador cambia el estado, registrar quién y cuándo.
create or replace function public.registrar_moderacion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.estado is distinct from old.estado then
    new.moderado_por := auth.uid();
    new.moderado_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists antes_actualizar_comentario on public.foro_comentarios;
create trigger antes_actualizar_comentario
before update on public.foro_comentarios
for each row execute function public.registrar_moderacion();


-- Setear updated_at automáticamente
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists perfiles_updated on public.perfiles;
create trigger perfiles_updated
before update on public.perfiles
for each row execute function public.set_updated_at();

drop trigger if exists eval_updated on public.evaluaciones_itinerario;
create trigger eval_updated
before update on public.evaluaciones_itinerario
for each row execute function public.set_updated_at();


-- ───────────────────────────────────────────────────────────────────
-- 6. ROW-LEVEL SECURITY (RLS)
-- ───────────────────────────────────────────────────────────────────
-- Cada tabla enciende RLS y declara políticas explícitas.
-- Sin RLS, cualquiera con el anon_key podría leer/escribir todo.

alter table public.perfiles enable row level security;
alter table public.foro_comentarios enable row level security;
alter table public.foro_reacciones enable row level security;
alter table public.evaluaciones_itinerario enable row level security;


-- ─── PERFILES ─────────────────────────────────────────────────
-- Cualquier autenticado lee perfiles (para mostrar nombre + país
-- junto a los comentarios).
drop policy if exists "perfiles: lectura autenticados" on public.perfiles;
create policy "perfiles: lectura autenticados"
on public.perfiles for select
to authenticated
using (true);

-- El usuario actualiza solo el suyo.
drop policy if exists "perfiles: dueño actualiza" on public.perfiles;
create policy "perfiles: dueño actualiza"
on public.perfiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- Nunca se inserta desde el cliente: solo el trigger.
-- Nunca se borra: si el usuario se borra, cascade hace el trabajo.


-- ─── FORO_COMENTARIOS ─────────────────────────────────────────
-- Todos leen los publicados.
drop policy if exists "foro: lectura publicados" on public.foro_comentarios;
create policy "foro: lectura publicados"
on public.foro_comentarios for select
to authenticated
using (estado = 'publicado');

-- El autor ve los propios en cualquier estado.
drop policy if exists "foro: autor ve propios" on public.foro_comentarios;
create policy "foro: autor ve propios"
on public.foro_comentarios for select
to authenticated
using (usuario_id = auth.uid());

-- Moderadores ven todo.
drop policy if exists "foro: moderadores ven todo" on public.foro_comentarios;
create policy "foro: moderadores ven todo"
on public.foro_comentarios for select
to authenticated
using (exists (
  select 1 from public.perfiles
  where id = auth.uid() and es_moderador = true
));

-- Cualquier autenticado inserta. El trigger fuerza estado='pendiente'.
drop policy if exists "foro: autenticados insertan" on public.foro_comentarios;
create policy "foro: autenticados insertan"
on public.foro_comentarios for insert
to authenticated
with check (usuario_id = auth.uid());

-- Solo moderadores actualizan (cambian estado a publicado/rechazado).
drop policy if exists "foro: moderadores actualizan" on public.foro_comentarios;
create policy "foro: moderadores actualizan"
on public.foro_comentarios for update
to authenticated
using (exists (
  select 1 from public.perfiles
  where id = auth.uid() and es_moderador = true
));

-- El autor puede borrar los propios (arrepentimiento).
drop policy if exists "foro: autor borra propios" on public.foro_comentarios;
create policy "foro: autor borra propios"
on public.foro_comentarios for delete
to authenticated
using (usuario_id = auth.uid());


-- ─── FORO_REACCIONES ──────────────────────────────────────────
-- Todos autenticados leen las reacciones.
drop policy if exists "reacciones: lectura autenticados" on public.foro_reacciones;
create policy "reacciones: lectura autenticados"
on public.foro_reacciones for select
to authenticated
using (true);

-- El usuario gestiona solo las propias.
drop policy if exists "reacciones: dueño gestiona" on public.foro_reacciones;
create policy "reacciones: dueño gestiona"
on public.foro_reacciones for all
to authenticated
using (usuario_id = auth.uid())
with check (usuario_id = auth.uid());


-- ─── EVALUACIONES ─────────────────────────────────────────────
-- El usuario ve solo la suya.
drop policy if exists "eval: dueño lee" on public.evaluaciones_itinerario;
create policy "eval: dueño lee"
on public.evaluaciones_itinerario for select
to authenticated
using (usuario_id = auth.uid());

-- Moderadores ven las evaluaciones marcadas para compartir.
drop policy if exists "eval: moderadores ven compartidas" on public.evaluaciones_itinerario;
create policy "eval: moderadores ven compartidas"
on public.evaluaciones_itinerario for select
to authenticated
using (
  compartir_con_equipo = true
  and exists (
    select 1 from public.perfiles
    where id = auth.uid() and es_moderador = true
  )
);

-- El usuario inserta la suya.
drop policy if exists "eval: dueño inserta" on public.evaluaciones_itinerario;
create policy "eval: dueño inserta"
on public.evaluaciones_itinerario for insert
to authenticated
with check (usuario_id = auth.uid());

-- El usuario actualiza la suya.
drop policy if exists "eval: dueño actualiza" on public.evaluaciones_itinerario;
create policy "eval: dueño actualiza"
on public.evaluaciones_itinerario for update
to authenticated
using (usuario_id = auth.uid())
with check (usuario_id = auth.uid());


-- ───────────────────────────────────────────────────────────────────
-- 7. FUNCIONES RPC (llamadas desde el frontend)
-- ───────────────────────────────────────────────────────────────────

-- Devuelve los comentarios publicados de un itinerario, o de toda
-- la escuela si p_scope='global', con agregado de reacciones y
-- las reacciones del usuario actual sobre cada uno.
create or replace function public.comentarios_para_itinerario(
  p_itinerario text,
  p_scope text default 'itinerario'
)
returns table (
  id uuid,
  itinerario_id text,
  itinerario_titulo text,
  parent_id uuid,
  autor_nombre text,
  pais text,
  modulo int,
  texto text,
  created_at timestamptz,
  reacciones jsonb,
  mis_reacciones jsonb
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  return query
  select
    c.id,
    c.itinerario_id,
    -- Título del itinerario: por ahora derivado del id.
    -- Si más adelante hacés una tabla `itinerarios`, joineá acá.
    replace(replace(c.itinerario_id, 'itinerario_', ''), '_', ' ') as itinerario_titulo,
    c.parent_id,
    c.autor_nombre,
    c.pais,
    c.modulo,
    c.texto,
    c.created_at,
    coalesce((
      select jsonb_object_agg(emoji, cnt)
      from (
        select r.emoji, count(*)::int as cnt
        from public.foro_reacciones r
        where r.comentario_id = c.id
        group by r.emoji
      ) x
    ), '{}'::jsonb) as reacciones,
    coalesce((
      select jsonb_agg(r.emoji)
      from public.foro_reacciones r
      where r.comentario_id = c.id
        and r.usuario_id = auth.uid()
    ), '[]'::jsonb) as mis_reacciones
  from public.foro_comentarios c
  where c.estado = 'publicado'
    and (p_scope = 'global' or c.itinerario_id = p_itinerario)
  order by c.created_at asc;
end;
$$;


-- Alterna una reacción del usuario actual sobre un comentario.
-- Si ya existe, la borra; si no, la crea.
create or replace function public.toggle_reaccion(
  p_comentario uuid,
  p_emoji text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_emoji not in ('🙏','❤️','💡','🕊️') then
    raise exception 'Emoji no permitido';
  end if;

  if exists (
    select 1 from public.foro_reacciones
    where comentario_id = p_comentario
      and usuario_id = auth.uid()
      and emoji = p_emoji
  ) then
    delete from public.foro_reacciones
    where comentario_id = p_comentario
      and usuario_id = auth.uid()
      and emoji = p_emoji;
  else
    insert into public.foro_reacciones(comentario_id, usuario_id, emoji)
    values (p_comentario, auth.uid(), p_emoji);
  end if;
end;
$$;


-- Permiso de ejecución a autenticados
grant execute on function public.comentarios_para_itinerario(text, text) to authenticated;
grant execute on function public.toggle_reaccion(uuid, text) to authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 8. CONVERTIR UN USUARIO EN MODERADOR
-- ───────────────────────────────────────────────────────────────────
-- Después de crear tu propia cuenta en la Escuela, ejecutá esto
-- (reemplazando el email) para que tu cuenta pueda moderar:
--
--   update public.perfiles
--   set es_moderador = true
--   where id = (select id from auth.users where email = 'tu-email@ejemplo.com');
--
-- Para dar moderación a otros miembros del equipo PLAPA, misma
-- consulta con su email.
-- ───────────────────────────────────────────────────────────────────

-- FIN DEL SCHEMA
