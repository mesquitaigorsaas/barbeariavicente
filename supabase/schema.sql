-- =====================================================================
-- Barbearia Vicente — agendamento online (Supabase / Postgres)
-- Cole tudo no Supabase → SQL Editor → Run. Pode rodar de novo sem problema.
--
-- Segurança:
--  - O site público NÃO lê a tabela de agendamentos. Ele só chama funções
--    (horários ocupados sem dados pessoais, criar e cancelar com código).
--  - Horário duplicado é impedido pelo próprio banco (exclusion constraint).
--  - Só quem está na tabela "admins" (o Carlão) vê e altera tudo no painel.
-- =====================================================================

create table if not exists services (
  id           serial primary key,
  name         text not null,
  description  text not null default '',
  price        numeric(8,2) not null,
  duration_min integer not null check (duration_min between 5 and 240),
  kind         text not null check (kind in ('main', 'extra')),  -- principal | adicional
  active       boolean not null default true,
  sort         integer not null default 0
);

-- Expediente por dia da semana (0 = domingo … 6 = sábado), horário de Maringá.
create table if not exists hours (
  weekday  integer primary key check (weekday between 0 and 6),
  closed   boolean not null default false,
  opens    time not null default '09:00',
  closes   time not null default '19:30'   -- o atendimento precisa terminar até aqui
);

create table if not exists settings (
  id              integer primary key default 1 check (id = 1),
  buffer_min      integer not null default 10,  -- intervalo entre clientes
  slot_step_min   integer not null default 20,  -- de quanto em quanto tempo oferecer horários
  min_notice_min  integer not null default 30,  -- antecedência mínima para agendar
  max_days        integer not null default 30,  -- até quantos dias à frente
  max_active_per_phone integer not null default 2
);

create table if not exists bookings (
  id             uuid primary key default gen_random_uuid(),
  token          uuid not null unique default gen_random_uuid(),  -- código para o cliente cancelar
  customer_name  text not null,
  customer_phone text not null,
  service_ids    integer[] not null,
  services_label text not null,
  total          numeric(8,2) not null,
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,   -- inclui o intervalo entre clientes
  status         text not null default 'confirmed' check (status in ('confirmed', 'done', 'no_show', 'cancelled')),
  notes          text not null default '',
  cancelled_by   text,                   -- cliente | barbearia
  created_at     timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists idx_bookings_start on bookings (starts_at);

-- Dois agendamentos ativos nunca ocupam o mesmo horário.
do $$ begin
  alter table bookings add constraint bookings_no_overlap
    exclude using gist (tstzrange(starts_at, ends_at) with &&) where (status in ('confirmed', 'done'));
exception when duplicate_object then null; end $$;

-- Horários bloqueados pelo Carlão (almoço, folga, compromisso…).
create table if not exists blocks (
  id         serial primary key,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  reason     text not null default '',
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Dados iniciais (preços e horários da plataforma atual, set/2026)
-- ---------------------------------------------------------------------
insert into settings (id) values (1) on conflict do nothing;

insert into hours (weekday, closed, opens, closes) values
  (0, true,  '09:00', '18:00'),
  (1, false, '13:00', '19:30'),
  (2, false, '09:00', '19:30'),
  (3, false, '09:00', '19:30'),
  (4, false, '09:00', '19:30'),
  (5, false, '09:00', '19:30'),
  (6, false, '08:00', '18:30')
on conflict do nothing;

insert into services (name, description, price, duration_min, kind, sort)
select * from (values
  ('Cabelo',          'Corte degradê ou social',                    40.00, 30, 'main', 1),
  ('Barba',           'Barba completa feita na navalha',            40.00, 30, 'main', 2),
  ('Cabelo e Barba',  'Combo premium com toalha quente',            80.00, 60, 'main', 3),
  ('Corte infantil',  'Crianças de 1 a 8 anos',                     45.00, 30, 'main', 4),
  ('Pezinho',         'Acabamento do pezinho',                      15.00, 10, 'extra', 10),
  ('Sobrancelha',     'Feita na navalha',                           15.00, 10, 'extra', 11),
  ('Depilação nariz', 'Com cera preta',                             18.00,  5, 'extra', 12),
  ('Depilação orelha','Com cera preta',                             18.00,  5, 'extra', 13),
  ('Ajeitar barba na máquina', 'Barba simples, sem navalha',        25.00, 15, 'extra', 14)
) as v(name, description, price, duration_min, kind, sort)
where not exists (select 1 from services);

-- ---------------------------------------------------------------------
-- Permissões (RLS)
-- ---------------------------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as
$$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;

alter table services enable row level security;
alter table hours    enable row level security;
alter table settings enable row level security;
alter table bookings enable row level security;
alter table blocks   enable row level security;
alter table admins   enable row level security;

drop policy if exists "leitura pública" on services;
create policy "leitura pública" on services for select using (true);
drop policy if exists "admin altera" on services;
create policy "admin altera" on services for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leitura pública" on hours;
create policy "leitura pública" on hours for select using (true);
drop policy if exists "admin altera" on hours;
create policy "admin altera" on hours for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leitura pública" on settings;
create policy "leitura pública" on settings for select using (true);
drop policy if exists "admin altera" on settings;
create policy "admin altera" on settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin" on bookings;
create policy "admin" on bookings for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin" on blocks;
create policy "admin" on blocks for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "vê o próprio" on admins;
create policy "vê o próprio" on admins for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Funções usadas pelo site público
-- ---------------------------------------------------------------------

-- Intervalos ocupados de um dia (sem nome nem telefone de ninguém).
create or replace function public.busy_intervals(p_day date)
returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as
$$
  with d as (
    select (p_day::timestamp at time zone 'America/Sao_Paulo') as d0,
           ((p_day + 1)::timestamp at time zone 'America/Sao_Paulo') as d1
  )
  select b.starts_at, b.ends_at from public.bookings b, d
   where b.status in ('confirmed', 'done') and b.starts_at < d.d1 and b.ends_at > d.d0
  union all
  select k.starts_at, k.ends_at from public.blocks k, d
   where k.starts_at < d.d1 and k.ends_at > d.d0
$$;

create or replace function public.create_booking(
  p_service_ids integer[], p_start timestamptz, p_name text, p_phone text, p_notes text default ''
) returns table (token uuid, starts_at timestamptz, services_label text, total numeric)
language plpgsql security definer set search_path = '' as
$$
#variable_conflict use_column
declare
  cfg     public.settings;
  h       public.hours;
  local_t timestamp := p_start at time zone 'America/Sao_Paulo';
  dur     integer;
  n_main  integer;
  lbl     text;
  tot     numeric;
  phone   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  name    text := btrim(coalesce(p_name, ''));
  v_end   timestamptz;
  v_token uuid;
begin
  select * into cfg from public.settings where id = 1;

  if length(name) < 2 or length(name) > 60 then raise exception 'Informe seu nome.' using errcode = 'P0001'; end if;
  if length(phone) < 10 or length(phone) > 13 then raise exception 'Informe um WhatsApp válido com DDD.' using errcode = 'P0001'; end if;

  select count(*) filter (where kind = 'main'), coalesce(sum(duration_min), 0), string_agg(s.name, ' + ' order by sort), coalesce(sum(price), 0)
    into n_main, dur, lbl, tot
    from public.services s where s.id = any (p_service_ids) and s.active;
  if n_main <> 1 or cardinality(p_service_ids) <> (select count(*) from public.services s where s.id = any (p_service_ids) and s.active) then
    raise exception 'Escolha um serviço principal.' using errcode = 'P0001';
  end if;

  if p_start < now() + make_interval(mins => cfg.min_notice_min) then
    raise exception 'Esse horário já passou ou está muito em cima. Escolha outro.' using errcode = 'P0001';
  end if;
  if p_start > now() + make_interval(days => cfg.max_days) then
    raise exception 'Agendamentos só até % dias à frente.', cfg.max_days using errcode = 'P0001';
  end if;

  select * into h from public.hours where weekday = extract(dow from local_t)::int;
  if h.closed or local_t::time < h.opens or (local_t + make_interval(mins => dur))::time > h.closes
     or (local_t + make_interval(mins => dur))::date <> local_t::date then
    raise exception 'Fora do horário de atendimento.' using errcode = 'P0001';
  end if;

  v_end := p_start + make_interval(mins => dur + cfg.buffer_min);

  if exists (select 1 from public.blocks k where k.starts_at < v_end and k.ends_at > p_start) then
    raise exception 'Esse horário acabou de ser ocupado. Escolha outro.' using errcode = 'P0001';
  end if;

  if (select count(*) from public.bookings b where b.customer_phone = phone and b.status = 'confirmed' and b.starts_at > now())
     >= cfg.max_active_per_phone then
    raise exception 'Você já tem agendamentos marcados. Fale com a barbearia no WhatsApp para marcar mais.' using errcode = 'P0001';
  end if;

  begin
    insert into public.bookings (customer_name, customer_phone, service_ids, services_label, total, starts_at, ends_at, notes)
    values (name, phone, p_service_ids, lbl, tot, p_start, v_end, left(btrim(coalesce(p_notes, '')), 300))
    returning bookings.token into v_token;
  exception when exclusion_violation then
    raise exception 'Esse horário acabou de ser ocupado. Escolha outro.' using errcode = 'P0001';
  end;

  return query select v_token, p_start, lbl, tot;
end
$$;

-- Consulta pelo código (link de cancelamento enviado ao cliente).
create or replace function public.get_booking(p_token uuid)
returns table (customer_name text, services_label text, total numeric, starts_at timestamptz, status text)
language sql stable security definer set search_path = '' as
$$ select b.customer_name, b.services_label, b.total, b.starts_at, b.status from public.bookings b where b.token = p_token $$;

create or replace function public.cancel_booking(p_token uuid) returns boolean
language plpgsql security definer set search_path = '' as
$$
begin
  update public.bookings set status = 'cancelled', cancelled_by = 'cliente'
   where token = p_token and status = 'confirmed' and starts_at > now();
  return found;
end
$$;

revoke all on function public.busy_intervals(date) from public;
revoke all on function public.create_booking(integer[], timestamptz, text, text, text) from public;
revoke all on function public.get_booking(uuid) from public;
revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.busy_intervals(date) to anon, authenticated;
grant execute on function public.create_booking(integer[], timestamptz, text, text, text) to anon, authenticated;
grant execute on function public.get_booking(uuid) to anon, authenticated;
grant execute on function public.cancel_booking(uuid) to anon, authenticated;
