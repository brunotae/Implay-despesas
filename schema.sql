-- =====================================================================
-- Implay Despesas · estrutura do banco (Supabase / Postgres)
-- Cole tudo no Supabase: SQL Editor > New query > Run.
-- Pode rodar de novo sem quebrar nada (é idempotente).
-- =====================================================================

-- ---------- Pessoas com acesso ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  nome        text not null default '',
  nivel       text not null default 'basic'    check (nivel  in ('adm','manager','basic')),
  status      text not null default 'pendente' check (status in ('pendente','ativo','bloqueado')),
  criado_em   timestamptz not null default now()
);

-- Convites: e-mails já liberados antes de a pessoa criar a conta.
create table if not exists public.convites (
  email      text primary key,
  nome       text not null,
  nivel      text not null default 'basic' check (nivel in ('adm','manager','basic')),
  criado_em  timestamptz not null default now()
);

-- Sócios já liberados (troque ou apague como quiser)
insert into public.convites (email, nome, nivel) values
  ('thiago.maghamez@gmail.com', 'Thiago', 'adm'),
  ('pgssallun@gmail.com',       'Pedro',  'adm'),
  ('caiomoreira.dg@gmail.com',  'Caio',   'adm'),
  ('dlauref@gmail.com',         'Dani',   'adm')
on conflict (email) do nothing;

-- ---------- Despesas ----------
create table if not exists public.despesas (
  id             uuid primary key default gen_random_uuid(),
  valor          numeric(12,2) not null check (valor > 0),
  data           date not null default current_date,
  descricao      text not null default '',
  favorecido     text not null default '',
  doc_favorecido text not null default '',
  categoria      text not null default '',
  forma          text not null default 'PIX',
  origem         text not null default 'pessoal' check (origem in ('pessoal','empresa')),
  pagador_id     uuid references public.profiles(id),
  pagador_nome   text not null default '',
  comprovantes   jsonb not null default '[]'::jsonb,
  obs            text not null default '',
  aprov          text not null default 'pendente' check (aprov in ('pendente','aprovada','recusada')),
  aprov_por      uuid references public.profiles(id),
  aprov_em       timestamptz,
  motivo         text not null default '',
  reemb          text check (reemb in ('a reembolsar','reembolsado')),
  reemb_por      uuid references public.profiles(id),
  reemb_em       timestamptz,
  conciliado     boolean not null default false,
  lancado_por    uuid not null default auth.uid() references public.profiles(id),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create index if not exists despesas_data_idx on public.despesas (data desc);

-- ---------- Histórico (só acrescenta, nunca apaga) ----------
create table if not exists public.historico (
  id          bigserial primary key,
  despesa_id  uuid,
  quem        uuid default auth.uid() references public.profiles(id),
  acao        text not null,
  em          timestamptz not null default now()
);
create index if not exists historico_em_idx on public.historico (em desc);

-- ---------- Funções de apoio ----------
create or replace function public.meu_nivel() returns text
language sql stable security definer set search_path = public as $$
  select nivel from public.profiles where id = auth.uid() and status = 'ativo'
$$;

create or replace function public.sou_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'ativo')
$$;

-- Quando alguém cria conta: o primeiro vira ADM; convidados entram liberados; os demais ficam pendentes.
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare c record; primeiro boolean;
begin
  select not exists (select 1 from public.profiles) into primeiro;
  select * into c from public.convites where lower(email) = lower(new.email);
  insert into public.profiles (id, email, nome, nivel, status)
  values (
    new.id, new.email,
    coalesce(c.nome, split_part(new.email, '@', 1)),
    case when primeiro then 'adm' when c.email is not null then c.nivel else 'basic' end,
    case when primeiro or c.email is not null then 'ativo' else 'pendente' end
  ) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.novo_usuario();

-- Regras de aprovação aplicadas pelo próprio banco (não dá para burlar pelo app).
create or replace function public.regras_despesa() returns trigger
language plpgsql security definer set search_path = public as $$
declare nv text := public.meu_nivel();
begin
  if tg_op = 'INSERT' then
    new.lancado_por := auth.uid();
    new.criado_em := now();
    if new.origem = 'empresa' then new.reemb := null; new.pagador_id := null;
    else new.reemb := 'a reembolsar'; end if;
    -- ADM lança já aprovado, menos reembolso para ele mesmo (aí outro ADM aprova)
    if nv = 'adm' and not (new.origem = 'pessoal' and new.pagador_id = auth.uid()) then
      new.aprov := 'aprovada'; new.aprov_por := auth.uid(); new.aprov_em := now();
    else
      new.aprov := 'pendente'; new.aprov_por := null; new.aprov_em := null;
    end if;
    new.reemb_por := null; new.reemb_em := null;
    return new;
  end if;

  -- UPDATE
  new.lancado_por := old.lancado_por;
  new.criado_em := old.criado_em;
  new.atualizado_em := now();
  if new.origem = 'empresa' then new.reemb := null; new.pagador_id := null;
  elsif new.reemb is null then new.reemb := 'a reembolsar'; end if;

  if nv is distinct from 'adm' then
    -- Manager só edita o que lançou e ainda está pendente; não aprova nem reembolsa
    new.aprov := 'pendente'; new.aprov_por := null; new.aprov_em := null;
    new.reemb := old.reemb; new.reemb_por := old.reemb_por; new.reemb_em := old.reemb_em;
    new.conciliado := old.conciliado;
  else
    if new.aprov <> old.aprov and new.aprov in ('aprovada','recusada') then
      if new.origem = 'pessoal' and new.pagador_id = auth.uid() then
        raise exception 'Reembolso para você mesmo precisa ser aprovado por outro ADM.';
      end if;
      new.aprov_por := auth.uid(); new.aprov_em := now();
    end if;
    if new.reemb = 'reembolsado' and old.reemb is distinct from 'reembolsado' then
      if new.aprov <> 'aprovada' then raise exception 'Aprove a despesa antes de reembolsar.'; end if;
      new.reemb_por := auth.uid(); new.reemb_em := now();
    end if;
  end if;
  return new;
end $$;
drop trigger if exists despesas_regras on public.despesas;
create trigger despesas_regras before insert or update on public.despesas
  for each row execute function public.regras_despesa();

-- ---------- Segurança por linha (quem vê e quem mexe) ----------
alter table public.profiles  enable row level security;
alter table public.convites  enable row level security;
alter table public.despesas  enable row level security;
alter table public.historico enable row level security;

drop policy if exists p_profiles_ver     on public.profiles;
drop policy if exists p_profiles_adm     on public.profiles;
drop policy if exists p_convites_adm     on public.convites;
drop policy if exists p_desp_ver         on public.despesas;
drop policy if exists p_desp_lancar      on public.despesas;
drop policy if exists p_desp_editar      on public.despesas;
drop policy if exists p_desp_apagar      on public.despesas;
drop policy if exists p_hist_ver         on public.historico;
drop policy if exists p_hist_escrever    on public.historico;

create policy p_profiles_ver  on public.profiles for select using (id = auth.uid() or public.sou_ativo());
create policy p_profiles_adm  on public.profiles for update using (public.meu_nivel() = 'adm') with check (public.meu_nivel() = 'adm');
create policy p_convites_adm  on public.convites for all    using (public.meu_nivel() = 'adm') with check (public.meu_nivel() = 'adm');

create policy p_desp_ver      on public.despesas for select using (public.sou_ativo());
create policy p_desp_lancar   on public.despesas for insert with check (public.meu_nivel() in ('adm','manager'));
create policy p_desp_editar   on public.despesas for update
  using (public.meu_nivel() = 'adm' or (public.meu_nivel() = 'manager' and lancado_por = auth.uid() and aprov = 'pendente'))
  with check (public.meu_nivel() in ('adm','manager'));
create policy p_desp_apagar   on public.despesas for delete using (public.meu_nivel() = 'adm');

create policy p_hist_ver      on public.historico for select using (public.sou_ativo());
-- (ninguém escreve no histórico pelo app: o próprio banco grava, veja abaixo)

-- ---------- Histórico automático ----------
create or replace function public.brl(v numeric) returns text language sql immutable as $$
  select 'R$ ' || replace(replace(replace(to_char(v, 'FM999,999,990.00'), ',', '#'), '.', ','), '#', '.')
$$;

create or replace function public.log_despesa() returns trigger
language plpgsql security definer set search_path = public as $$
declare a text;
begin
  if tg_op = 'INSERT' then
    a := 'lançou ' || brl(new.valor) || case when new.aprov = 'aprovada' then ' (aprovada automaticamente)' else ' (aguardando aprovação)' end;
    insert into historico (despesa_id, quem, acao) values (new.id, auth.uid(), a);
    return new;
  elsif tg_op = 'DELETE' then
    insert into historico (despesa_id, quem, acao) values (null, auth.uid(),
      'excluiu ' || coalesce(nullif(old.favorecido,''), nullif(old.descricao,''), 'gasto') || ' de ' || brl(old.valor));
    return old;
  end if;
  if new.aprov <> old.aprov and new.aprov = 'aprovada' then
    insert into historico (despesa_id, quem, acao) values (new.id, auth.uid(), 'aprovou');
  elsif new.aprov <> old.aprov and new.aprov = 'recusada' then
    insert into historico (despesa_id, quem, acao) values (new.id, auth.uid(), 'recusou: ' || new.motivo);
  end if;
  if new.reemb is distinct from old.reemb and new.reemb = 'reembolsado' then
    insert into historico (despesa_id, quem, acao) values (new.id, auth.uid(), 'marcou como reembolsado');
  end if;
  if (new.valor, new.data, new.descricao, new.favorecido, new.doc_favorecido, new.categoria, new.forma, new.origem, new.pagador_id, new.pagador_nome, new.comprovantes, new.obs)
     is distinct from
     (old.valor, old.data, old.descricao, old.favorecido, old.doc_favorecido, old.categoria, old.forma, old.origem, old.pagador_id, old.pagador_nome, old.comprovantes, old.obs) then
    insert into historico (despesa_id, quem, acao) values (new.id, auth.uid(),
      'editou' || case when new.valor <> old.valor then ' (valor de ' || brl(old.valor) || ' para ' || brl(new.valor) || ')' else '' end);
  end if;
  return new;
end $$;
drop trigger if exists despesas_log on public.despesas;
create trigger despesas_log after insert or update or delete on public.despesas
  for each row execute function public.log_despesa();

create or replace function public.log_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> old.status then
    insert into historico (quem, acao) values (auth.uid(),
      case new.status when 'ativo' then 'liberou o acesso de ' when 'bloqueado' then 'bloqueou o acesso de ' else 'mudou para pendente o acesso de ' end || new.nome);
  end if;
  if new.nivel <> old.nivel then
    insert into historico (quem, acao) values (auth.uid(), 'mudou o nível de ' || new.nome || ' para ' ||
      case new.nivel when 'adm' then 'ADM' when 'manager' then 'Manager' else 'Basic' end);
  end if;
  return new;
end $$;
drop trigger if exists profiles_log on public.profiles;
create trigger profiles_log after update on public.profiles
  for each row execute function public.log_profile();

-- ---------- Fotos e PDFs dos comprovantes ----------
insert into storage.buckets (id, name, public) values ('comprovantes', 'comprovantes', false)
on conflict (id) do nothing;

drop policy if exists p_comp_ver     on storage.objects;
drop policy if exists p_comp_enviar  on storage.objects;
drop policy if exists p_comp_apagar  on storage.objects;
create policy p_comp_ver    on storage.objects for select using (bucket_id = 'comprovantes' and public.sou_ativo());
create policy p_comp_enviar on storage.objects for insert with check (bucket_id = 'comprovantes' and public.meu_nivel() in ('adm','manager'));
create policy p_comp_apagar on storage.objects for delete using (bucket_id = 'comprovantes' and public.meu_nivel() in ('adm','manager'));

-- ---------- Atualização ao vivo entre aparelhos ----------
do $$ begin
  begin alter publication supabase_realtime add table public.despesas; exception when others then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when others then null; end;
end $$;
