-- =====================================================================
--  IMPRESOS Y PUBLICIDAD · Base de datos en Supabase
--  Correo del panel: impresionesypublicidadmedellin@gmail.com
--  Pega todo esto en Supabase → SQL Editor → New query → Run.
-- =====================================================================

-- Quién puede entrar al panel
create table if not exists public.admins (email text primary key);
insert into public.admins(email) values ('impresionesypublicidadmedellin@gmail.com') on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where lower(email) = lower(coalesce(auth.jwt()->>'email','')));
$$;

-- Catálogo, precios, entregas y textos de la página (lo ve todo el mundo)
create table if not exists public.config (
  id int primary key default 1 check (id = 1),
  data jsonb not null,
  updated_at timestamptz default now()
);

-- Inventario (solo tú)
create table if not exists public.materials (id text primary key, data jsonb not null);

-- Pedidos (solo tú; las clientas crean pedidos con la función place_order)
create table if not exists public.orders (
  code text primary key,
  data jsonb not null,
  created_at timestamptz default now()
);

-- Movimientos de inventario (solo tú)
create table if not exists public.moves (
  id bigint generated always as identity primary key,
  t timestamptz default now(), m text, d int, r text, c int
);

create sequence if not exists public.order_seq start 1001;

-- Permisos básicos (la seguridad real la ponen las reglas de abajo)
grant select, insert, update, delete on public.config, public.materials, public.orders, public.moves to authenticated;
grant select on public.config to anon;

-- Seguridad
alter table public.admins    enable row level security;
alter table public.config    enable row level security;
alter table public.materials enable row level security;
alter table public.orders    enable row level security;
alter table public.moves     enable row level security;

drop policy if exists "config lectura" on public.config;
create policy "config lectura" on public.config for select to anon, authenticated using (true);
drop policy if exists "config admin" on public.config;
create policy "config admin" on public.config for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "materials admin" on public.materials;
create policy "materials admin" on public.materials for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "orders admin" on public.orders;
create policy "orders admin" on public.orders for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "moves admin" on public.moves;
create policy "moves admin" on public.moves for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- La clienta envía su pedido: se crea el número y se aparta el material
create or replace function public.place_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code text; it jsonb; rq jsonb; uses jsonb; items jsonb := '[]'::jsonb;
  st int; nd int; got int;
begin
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 or jsonb_array_length(p->'items') > 30 then
    raise exception 'Pedido inválido';
  end if;
  if length(coalesce(p->>'name','')) < 2 or length(regexp_replace(coalesce(p->>'wa',''),'\D','','g')) < 7 then
    raise exception 'Faltan datos';
  end if;
  v_code := 'IP-' || nextval('public.order_seq');
  for it in select * from jsonb_array_elements(p->'items') loop
    uses := '[]'::jsonb;
    for rq in select * from jsonb_array_elements(coalesce(it->'req','[]'::jsonb)) loop
      nd := greatest(0, least(100000, coalesce((rq->>'need')::int, 0)));
      select (data->>'stock')::int into st from public.materials where id = rq->>'m' for update;
      if st is null then continue; end if;
      got := least(st, nd);
      update public.materials set data = jsonb_set(data, '{stock}', to_jsonb(st - got)) where id = rq->>'m';
      if got > 0 then insert into public.moves(m, d, r) values (rq->>'m', -got, 'Pedido ' || v_code); end if;
      uses := uses || jsonb_build_object('m', rq->>'m', 'need', nd, 'got', got);
    end loop;
    items := items || ((it - 'req') || jsonb_build_object('use', uses));
  end loop;
  insert into public.orders(code, data) values (v_code,
    (p - 'items' - 'pays') || jsonb_build_object('code', v_code, 'items', items, 'status', 'recibido',
      'date', now(), 'hist', jsonb_build_array(jsonb_build_object('s','recibido','t', now()))));
  return v_code;
end $$;

-- La clienta consulta su pedido con el número y los últimos 4 dígitos de su WhatsApp
create or replace function public.track_order(p_code text, p_last4 text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('code', code, 'status', data->'status', 'hist', data->'hist',
           'how', data->'how', 'zone', data->'zone',
           'items', (select coalesce(jsonb_agg(jsonb_build_object('design', i->'design', 'designTxt', i->'designTxt')), '[]'::jsonb)
                     from jsonb_array_elements(data->'items') i))
  from public.orders
  where code = upper(trim(p_code)) and length(p_last4) = 4 and right(regexp_replace(data->>'wa','\D','','g'), 4) = p_last4;
$$;

revoke all on function public.place_order(jsonb) from public;
revoke all on function public.track_order(text, text) from public;
grant execute on function public.place_order(jsonb) to anon, authenticated;
grant execute on function public.track_order(text, text) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;

-- Fotos de la página (todo el mundo las ve; solo tú las subes)
insert into storage.buckets (id, name, public) values ('fotos', 'fotos', true) on conflict (id) do nothing;
drop policy if exists "fotos subir" on storage.objects;
create policy "fotos subir" on storage.objects for insert to authenticated with check (bucket_id = 'fotos' and public.is_admin());
drop policy if exists "fotos cambiar" on storage.objects;
create policy "fotos cambiar" on storage.objects for update to authenticated using (bucket_id = 'fotos' and public.is_admin());
drop policy if exists "fotos borrar" on storage.objects;
create policy "fotos borrar" on storage.objects for delete to authenticated using (bucket_id = 'fotos' and public.is_admin());

-- (Opcional) Para que los pedidos empiecen en otro número, por ejemplo 2000:
-- select setval('public.order_seq', 1999);
