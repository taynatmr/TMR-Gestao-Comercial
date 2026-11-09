-- =====================================================================
--  SISTEMA DE GESTÃO COMERCIAL — Estrutura do banco (Supabase / PostgreSQL)
--  Versão 1 (Etapa 1: estrutura completa de todos os módulos)
--
--  Como usar: Supabase → SQL Editor → New query → colar TODO este arquivo → Run.
--  O script pode ser executado mais de uma vez sem apagar dados.
--
--  Modelo de acesso: cada usuário pertence a UMA empresa (tabela membros).
--  Todas as tabelas têm empresa_id preenchido automaticamente e protegido por RLS:
--  um usuário só enxerga e altera os dados da própria empresa.
--  Papéis: admin (tudo) e vendedor (não exclui cadastros nem altera configurações).
-- =====================================================================

set client_min_messages = warning;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. EMPRESA E USUÁRIOS
-- ---------------------------------------------------------------------
create table if not exists public.empresas (
  id             uuid primary key default gen_random_uuid(),
  razao_social   text not null default '',
  nome_fantasia  text not null default '',
  documento      text not null default '',          -- CNPJ ou CPF
  telefone       text not null default '',
  email          text not null default '',
  endereco       text not null default '',
  logo_url       text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create table if not exists public.membros (
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  papel       text not null default 'admin' check (papel in ('admin','vendedor')),
  criado_em   timestamptz not null default now(),
  primary key (empresa_id, user_id)
);
create unique index if not exists membros_um_por_usuario on public.membros(user_id);

-- Empresa do usuário logado (usada como valor padrão e nas políticas RLS)
create or replace function public.minha_empresa() returns uuid
language sql stable security definer set search_path = public as $$
  select empresa_id from public.membros where user_id = auth.uid() limit 1
$$;

create or replace function public.sou_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.membros where user_id = auth.uid() and papel = 'admin')
$$;

-- Atualiza a coluna atualizado_em
create or replace function public.tg_atualizado_em() returns trigger
language plpgsql as $$ begin new.atualizado_em := now(); return new; end $$;

-- ---------------------------------------------------------------------
-- 2. CADASTROS
-- ---------------------------------------------------------------------
create table if not exists public.fornecedores (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  nome         text not null check (length(trim(nome)) > 0),
  telefone     text not null default '',
  email        text not null default '',
  endereco     text not null default '',
  atendente    text not null default '',
  observacao   text not null default '',
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.clientes (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  nome         text not null check (length(trim(nome)) > 0),
  telefone     text not null default '',
  email        text not null default '',
  endereco     text not null default '',
  documento    text not null default '',
  observacao   text not null default '',
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Produtos: o MESMO registro serve ao Estoque e à Base de Cálculo (sem duplicidade)
create table if not exists public.produtos (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  nome             text not null check (length(trim(nome)) > 0),
  especificacao    text not null default '',
  categoria        text not null default '',
  unidade          text not null default 'un',
  foto_url         text,
  fornecedor_id    uuid references public.fornecedores(id) on delete set null,
  custo_materiais  numeric(14,2) not null default 0 check (custo_materiais >= 0),
  custo_horas      numeric(14,2) not null default 0 check (custo_horas >= 0),
  custo            numeric(14,2) generated always as (custo_materiais + custo_horas) stored,
  lucro_percentual numeric(9,2)  not null default 0,
  preco_venda      numeric(14,2) not null default 0 check (preco_venda >= 0),
  quantidade       numeric(14,3) not null default 0,   -- alterada SOMENTE por movimentações
  estoque_minimo   numeric(14,3) not null default 0 check (estoque_minimo >= 0),
  ativo            boolean not null default true,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);
-- Composição detalhada do custo (v2):
--   materiais = [{descricao, valor_original, qtd_original, qtd_utilizada}]
--   custo_materiais = Σ valor_original ÷ qtd_original × qtd_utilizada
--   custo_horas     = valor_hora × horas_trabalhadas
alter table public.produtos add column if not exists materiais jsonb not null default '[]'::jsonb;
alter table public.produtos add column if not exists valor_hora numeric(14,2) not null default 0;
alter table public.produtos add column if not exists horas_trabalhadas numeric(10,2) not null default 0;

create or replace function public.tg_produto_custos() returns trigger
language plpgsql as $$
declare m jsonb; v numeric := 0; qo numeric; vo numeric; qu numeric;
begin
  if new.materiais is null or jsonb_typeof(new.materiais) <> 'array' then new.materiais := '[]'::jsonb; end if;
  if new.valor_hora < 0 or new.horas_trabalhadas < 0 then raise exception 'Os valores das horas não podem ser negativos.'; end if;
  if jsonb_array_length(new.materiais) > 0 then
    for m in select * from jsonb_array_elements(new.materiais) loop
      qo := coalesce((m->>'qtd_original')::numeric, 0);
      vo := coalesce((m->>'valor_original')::numeric, 0);
      qu := coalesce((m->>'qtd_utilizada')::numeric, 0);
      if qo <= 0 then raise exception 'Informe a quantidade original de cada material (maior que zero).'; end if;
      if vo < 0 or qu < 0 then raise exception 'Os valores dos materiais não podem ser negativos.'; end if;
      v := v + vo / qo * qu;
    end loop;
    new.custo_materiais := round(v, 2);
  end if;
  if new.valor_hora > 0 or new.horas_trabalhadas > 0 then
    new.custo_horas := round(new.valor_hora * new.horas_trabalhadas, 2);
  end if;
  return new;
end $$;
drop trigger if exists produto_custos on public.produtos;
create trigger produto_custos before insert or update on public.produtos
  for each row execute function public.tg_produto_custos();

create unique index if not exists produtos_sem_duplicidade
  on public.produtos (empresa_id, lower(trim(nome)), lower(trim(especificacao)));
create index if not exists produtos_empresa_categoria on public.produtos (empresa_id, categoria);

-- Serviços: preço final = valor da hora × horas trabalhadas (calculado pelo banco)
create table if not exists public.servicos (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  nome              text not null check (length(trim(nome)) > 0),
  especificacao     text not null default '',
  categoria         text not null default '',
  foto_url          text,
  valor_hora        numeric(14,2) not null default 0 check (valor_hora >= 0),
  horas_trabalhadas numeric(10,2) not null default 0 check (horas_trabalhadas >= 0),
  preco             numeric(14,2) generated always as (round(valor_hora * horas_trabalhadas, 2)) stored,
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now()
);
create unique index if not exists servicos_sem_duplicidade
  on public.servicos (empresa_id, lower(trim(nome)), lower(trim(especificacao)));

-- ---------------------------------------------------------------------
-- 3. VENDAS, ORÇAMENTOS E FINANCEIRO
-- ---------------------------------------------------------------------
create table if not exists public.orcamentos (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  numero          integer not null,
  cliente_id      uuid references public.clientes(id) on delete set null,
  cliente_nome    text not null default '',
  data            timestamptz not null default now(),
  validade        date,
  subtotal        numeric(14,2) not null default 0,
  desconto_tipo   text not null default 'valor' check (desconto_tipo in ('valor','percentual')),
  desconto_valor  numeric(14,2) not null default 0 check (desconto_valor >= 0),
  desconto_total  numeric(14,2) not null default 0,
  total           numeric(14,2) not null default 0,
  status          text not null default 'aberto'
                  check (status in ('aberto','enviado','aprovado','recusado','convertido')),
  observacao      text not null default '',
  venda_id        uuid,  -- FK criada após a tabela vendas
  usuario_id      uuid default auth.uid(),
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  unique (empresa_id, numero)
);

create table if not exists public.orcamento_itens (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  orcamento_id   uuid not null references public.orcamentos(id) on delete cascade,
  tipo           text not null check (tipo in ('produto','servico')),
  produto_id     uuid references public.produtos(id) on delete set null,
  servico_id     uuid references public.servicos(id) on delete set null,
  descricao      text not null,
  especificacao  text not null default '',
  categoria      text not null default '',
  quantidade     numeric(14,3) not null check (quantidade > 0),
  preco_unitario numeric(14,2) not null check (preco_unitario >= 0),
  custo_unitario numeric(14,2) not null default 0,
  total          numeric(14,2) not null
);

create table if not exists public.vendas (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  numero              integer not null,
  cliente_id          uuid references public.clientes(id) on delete set null,
  cliente_nome        text not null default '',
  data                timestamptz not null default now(),
  subtotal            numeric(14,2) not null default 0,
  desconto_tipo       text not null default 'valor' check (desconto_tipo in ('valor','percentual')),
  desconto_valor      numeric(14,2) not null default 0 check (desconto_valor >= 0),
  desconto_total      numeric(14,2) not null default 0,
  total               numeric(14,2) not null default 0,
  forma_pagamento     text not null default '',
  num_parcelas        integer not null default 1 check (num_parcelas >= 1),
  status              text not null default 'confirmada' check (status in ('confirmada','cancelada')),
  cancelada_em        timestamptz,
  motivo_cancelamento text not null default '',
  orcamento_id        uuid unique references public.orcamentos(id) on delete set null,
  recibo_url          text,
  observacao          text not null default '',
  usuario_id          uuid default auth.uid(),
  criado_em           timestamptz not null default now(),
  unique (empresa_id, numero)
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orcamentos_venda_fk') then
    alter table public.orcamentos
      add constraint orcamentos_venda_fk foreign key (venda_id) references public.vendas(id) on delete set null;
  end if;
end $$;

-- Itens com "fotografia" de preço e custo do momento da venda (preservados mesmo que o cadastro mude)
create table if not exists public.venda_itens (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  venda_id       uuid not null references public.vendas(id) on delete cascade,
  tipo           text not null check (tipo in ('produto','servico')),
  produto_id     uuid references public.produtos(id) on delete set null,
  servico_id     uuid references public.servicos(id) on delete set null,
  descricao      text not null,
  especificacao  text not null default '',
  categoria      text not null default '',
  quantidade     numeric(14,3) not null check (quantidade > 0),
  preco_unitario numeric(14,2) not null check (preco_unitario >= 0),
  custo_unitario numeric(14,2) not null default 0,
  total          numeric(14,2) not null
);
create index if not exists venda_itens_venda on public.venda_itens (venda_id);

-- Contas a receber (uma linha por parcela; à vista = 1 parcela)
create table if not exists public.parcelas (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  venda_id         uuid not null references public.vendas(id) on delete cascade,
  numero           integer not null,
  valor            numeric(14,2) not null check (valor >= 0),
  vencimento       date not null,
  valor_pago       numeric(14,2) not null default 0 check (valor_pago >= 0),
  pago_em          date,
  forma_pagamento  text not null default '',
  observacao       text not null default '',
  atualizado_em    timestamptz not null default now(),
  unique (venda_id, numero)
);

-- ---------------------------------------------------------------------
-- 4. MOVIMENTAÇÃO DE ESTOQUE (histórico imutável)
-- ---------------------------------------------------------------------
create table if not exists public.movimentacoes_estoque (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null default public.minha_empresa() references public.empresas(id) on delete cascade,
  produto_id      uuid references public.produtos(id) on delete set null,
  produto_nome    text not null default '',
  tipo            text not null check (tipo in ('entrada','saida','ajuste','venda','cancelamento_venda')),
  delta           numeric(14,3) not null,           -- positivo = entrou, negativo = saiu
  saldo_apos      numeric(14,3),
  custo_unitario  numeric(14,2),
  fornecedor_id   uuid references public.fornecedores(id) on delete set null,
  documento       text not null default '',         -- nº da nota / pedido
  venda_id        uuid references public.vendas(id) on delete set null,
  observacao      text not null default '',
  data            timestamptz not null default now(),
  usuario_id      uuid default auth.uid(),
  check ( (tipo in ('entrada','cancelamento_venda') and delta > 0)
       or (tipo in ('saida','venda') and delta < 0)
       or (tipo = 'ajuste' and delta <> 0) )
);
create index if not exists mov_produto on public.movimentacoes_estoque (produto_id, data desc);
create index if not exists mov_fornecedor on public.movimentacoes_estoque (fornecedor_id, data desc);

-- Aplica a movimentação ao saldo do produto (com bloqueio de linha, impede saldo negativo)
create or replace function public.tg_mov_aplicar() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_qtd numeric; v_nome text; v_emp uuid;
begin
  select quantidade, nome, empresa_id into v_qtd, v_nome, v_emp
    from public.produtos where id = new.produto_id for update;
  if not found then raise exception 'Produto não encontrado.'; end if;
  if v_emp <> new.empresa_id then raise exception 'Produto de outra empresa.'; end if;
  if v_qtd + new.delta < 0 then
    raise exception 'Estoque insuficiente para "%": disponível %, solicitado %.',
      v_nome, trim(to_char(v_qtd,'FM999999990.###')), trim(to_char(-new.delta,'FM999999990.###'))
      using errcode = 'P0001';
  end if;
  new.saldo_apos   := v_qtd + new.delta;
  new.produto_nome := v_nome;
  perform set_config('app.movimentando', 'sim', true);
  update public.produtos set quantidade = v_qtd + new.delta where id = new.produto_id;
  perform set_config('app.movimentando', '', true);
  return new;
end $$;

drop trigger if exists mov_aplicar on public.movimentacoes_estoque;
create trigger mov_aplicar before insert on public.movimentacoes_estoque
  for each row execute function public.tg_mov_aplicar();

-- Impede alterar a quantidade do produto diretamente (só via movimentação)
create or replace function public.tg_produto_protege_qtd() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.quantidade := 0;   -- quantidade inicial entra como movimentação de entrada
  elsif new.quantidade is distinct from old.quantidade
        and coalesce(current_setting('app.movimentando', true), '') <> 'sim' then
    new.quantidade := old.quantidade;
  end if;
  return new;
end $$;

drop trigger if exists produto_protege_qtd on public.produtos;
create trigger produto_protege_qtd before insert or update on public.produtos
  for each row execute function public.tg_produto_protege_qtd();

-- Gatilhos de atualizado_em
do $$ declare t text; begin
  foreach t in array array['empresas','fornecedores','clientes','produtos','servicos','orcamentos','parcelas'] loop
    execute format('drop trigger if exists %I on public.%I', 'atualizado_'||t, t);
    execute format('create trigger %I before update on public.%I for each row execute function public.tg_atualizado_em()', 'atualizado_'||t, t);
  end loop;
end $$;

-- Numeração sequencial por empresa (vendas e orçamentos)
create or replace function public.tg_numerar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.numero is null or new.numero = 0 then
    perform pg_advisory_xact_lock(hashtext(tg_table_name || new.empresa_id::text));
    execute format('select coalesce(max(numero),0)+1 from public.%I where empresa_id = $1', tg_table_name)
      into new.numero using new.empresa_id;
  end if;
  return new;
end $$;

alter table public.vendas     alter column numero set default 0;
alter table public.orcamentos alter column numero set default 0;
drop trigger if exists numerar_venda on public.vendas;
create trigger numerar_venda before insert on public.vendas for each row execute function public.tg_numerar();
drop trigger if exists numerar_orcamento on public.orcamentos;
create trigger numerar_orcamento before insert on public.orcamentos for each row execute function public.tg_numerar();

-- Situação da parcela calculada (pago / parcial / pendente / vencido)
create or replace view public.v_parcelas with (security_invoker = on) as
select p.*,
       v.numero as venda_numero, v.cliente_id, v.cliente_nome, v.status as venda_status,
       greatest(p.valor - p.valor_pago, 0) as saldo,
       case when p.valor_pago >= p.valor then 'pago'
            when p.vencimento < current_date then 'vencido'
            when p.valor_pago > 0 then 'parcial'
            else 'pendente' end as situacao
  from public.parcelas p join public.vendas v on v.id = p.venda_id;

-- ---------------------------------------------------------------------
-- 5. FUNÇÕES DE NEGÓCIO (executadas de forma atômica no banco)
-- ---------------------------------------------------------------------

-- Primeiro acesso: cria a empresa e torna o usuário administrador
create or replace function public.criar_minha_empresa(p_nome text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Faça login.'; end if;
  select empresa_id into v_id from public.membros where user_id = auth.uid();
  if v_id is not null then return v_id; end if;
  insert into public.empresas (nome_fantasia, razao_social) values (coalesce(p_nome,''), coalesce(p_nome,''))
    returning id into v_id;
  insert into public.membros (empresa_id, user_id, papel) values (v_id, auth.uid(), 'admin');
  return v_id;
end $$;

-- Usuários da empresa (somente leitura de e-mail e papel)
create or replace function public.listar_membros()
returns table (user_id uuid, email text, papel text, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select m.user_id, u.email::text, m.papel, m.criado_em
    from public.membros m join auth.users u on u.id = m.user_id
   where m.empresa_id = public.minha_empresa()
   order by m.criado_em
$$;

-- Admin adiciona à empresa um usuário que já criou conta no sistema
create or replace function public.adicionar_membro(p_email text, p_papel text default 'vendedor') returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_emp uuid := public.minha_empresa();
begin
  if not public.sou_admin() then raise exception 'Somente administradores podem adicionar usuários.'; end if;
  if p_papel not in ('admin','vendedor') then raise exception 'Papel inválido.'; end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then raise exception 'Nenhuma conta encontrada com este e-mail. Peça para a pessoa criar a conta primeiro.'; end if;
  if exists (select 1 from public.membros where user_id = v_uid) then
    raise exception 'Este usuário já pertence a uma empresa.';
  end if;
  insert into public.membros (empresa_id, user_id, papel) values (v_emp, v_uid, p_papel);
end $$;

create or replace function public.remover_membro(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sou_admin() then raise exception 'Somente administradores podem remover usuários.'; end if;
  if p_user = auth.uid() then raise exception 'Você não pode remover a si mesmo.'; end if;
  delete from public.membros where user_id = p_user and empresa_id = public.minha_empresa();
end $$;

-- Calcula o desconto em R$
create or replace function public.calc_desconto(p_subtotal numeric, p_tipo text, p_valor numeric) returns numeric
language sql immutable as $$
  select least(p_subtotal, round(case when p_tipo = 'percentual'
                                      then p_subtotal * least(coalesce(p_valor,0),100) / 100
                                      else coalesce(p_valor,0) end, 2))
$$;

-- Registra uma venda completa: itens, baixa de estoque e parcelas — tudo ou nada.
-- p = {cliente_id, itens:[{tipo, id, quantidade}], desconto_tipo, desconto_valor,
--      forma_pagamento, num_parcelas, primeiro_vencimento (date), pago_agora (bool),
--      observacao, orcamento_id (opcional: usa itens e preços do orçamento aprovado)}
create or replace function public.registrar_venda(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_emp uuid := public.minha_empresa();
  v_venda uuid; v_cli_id uuid; v_cli_nome text; v_orc public.orcamentos%rowtype; it jsonb; r record;
  v_sub numeric := 0; v_desc numeric; v_total numeric;
  v_n int := greatest(coalesce((p->>'num_parcelas')::int, 1), 1);
  v_venc date := coalesce((p->>'primeiro_vencimento')::date, current_date);
  v_pago boolean := coalesce((p->>'pago_agora')::boolean, false);
  v_dtipo text := coalesce(p->>'desconto_tipo','valor');
  v_dval numeric := coalesce((p->>'desconto_valor')::numeric, 0);
  v_parc numeric; v_acum numeric := 0; i int;
begin
  if v_emp is null then raise exception 'Usuário sem empresa.'; end if;

  if p->>'orcamento_id' is not null then
    select * into v_orc from public.orcamentos where id = (p->>'orcamento_id')::uuid and empresa_id = v_emp for update;
    if not found then raise exception 'Orçamento não encontrado.'; end if;
    if v_orc.venda_id is not null or v_orc.status = 'convertido' then
      raise exception 'Este orçamento já foi convertido em venda.'; end if;
    if v_orc.status <> 'aprovado' then raise exception 'Somente orçamentos aprovados podem virar venda.'; end if;
    v_dtipo := v_orc.desconto_tipo; v_dval := v_orc.desconto_valor;
  end if;

  select id, nome into v_cli_id, v_cli_nome from public.clientes
   where id = coalesce((p->>'cliente_id')::uuid, v_orc.cliente_id) and empresa_id = v_emp;

  insert into public.vendas (cliente_id, cliente_nome, desconto_tipo, desconto_valor, forma_pagamento,
                             num_parcelas, observacao, orcamento_id)
  values (v_cli_id, coalesce(v_cli_nome, v_orc.cliente_nome, ''), v_dtipo, v_dval, coalesce(p->>'forma_pagamento',''),
          v_n, coalesce(p->>'observacao',''), v_orc.id)
  returning id into v_venda;

  if v_orc.id is not null then
    -- Itens e preços combinados no orçamento
    for r in select * from public.orcamento_itens where orcamento_id = v_orc.id loop
      insert into public.venda_itens (venda_id, tipo, produto_id, servico_id, descricao, especificacao, categoria,
                                      quantidade, preco_unitario, custo_unitario, total)
      values (v_venda, r.tipo, r.produto_id, r.servico_id, r.descricao, r.especificacao, r.categoria,
              r.quantidade, r.preco_unitario,
              coalesce((select custo from public.produtos where id = r.produto_id), r.custo_unitario),
              r.total);
      v_sub := v_sub + r.total;
    end loop;
  else
    if jsonb_array_length(coalesce(p->'itens','[]'::jsonb)) = 0 then raise exception 'Adicione ao menos um item.'; end if;
    for it in select * from jsonb_array_elements(p->'itens') loop
      if coalesce((it->>'quantidade')::numeric,0) <= 0 then raise exception 'Quantidade inválida.'; end if;
      if it->>'tipo' = 'produto' then
        select id, nome, especificacao, categoria, preco_venda as preco, custo into r
          from public.produtos where id = (it->>'id')::uuid and empresa_id = v_emp;
      else
        select id, nome, especificacao, categoria, preco, 0::numeric as custo into r
          from public.servicos where id = (it->>'id')::uuid and empresa_id = v_emp;
      end if;
      if not found then raise exception 'Item não encontrado.'; end if;
      insert into public.venda_itens (venda_id, tipo, produto_id, servico_id, descricao, especificacao, categoria,
                                      quantidade, preco_unitario, custo_unitario, total)
      values (v_venda, it->>'tipo',
              case when it->>'tipo'='produto' then r.id end, case when it->>'tipo'='servico' then r.id end,
              r.nome, r.especificacao, r.categoria, (it->>'quantidade')::numeric, r.preco, r.custo,
              round(r.preco * (it->>'quantidade')::numeric, 2));
      v_sub := v_sub + round(r.preco * (it->>'quantidade')::numeric, 2);
    end loop;
  end if;

  -- Baixa de estoque (somente produtos)
  for r in select produto_id, sum(quantidade) q from public.venda_itens
            where venda_id = v_venda and tipo = 'produto' and produto_id is not null group by produto_id loop
    insert into public.movimentacoes_estoque (produto_id, tipo, delta, venda_id, observacao)
    values (r.produto_id, 'venda', -r.q, v_venda, 'Venda');
  end loop;

  v_desc  := public.calc_desconto(v_sub, v_dtipo, v_dval);
  v_total := v_sub - v_desc;
  update public.vendas set subtotal = v_sub, desconto_total = v_desc, total = v_total where id = v_venda;
  update public.movimentacoes_estoque m set observacao = 'Venda nº ' || v.numero
    from public.vendas v where v.id = v_venda and m.venda_id = v_venda;

  -- Parcelas
  v_parc := round(v_total / v_n, 2);
  for i in 1..v_n loop
    insert into public.parcelas (venda_id, numero, valor, vencimento, forma_pagamento, valor_pago, pago_em)
    values (v_venda, i,
            case when i = v_n then v_total - v_acum else v_parc end,
            (v_venc + ((i-1) || ' month')::interval)::date,
            coalesce(p->>'forma_pagamento',''),
            case when v_pago and i = 1 then (case when i = v_n then v_total - v_acum else v_parc end) else 0 end,
            case when v_pago and i = 1 then current_date end);
    v_acum := v_acum + v_parc;
  end loop;

  if v_orc.id is not null then
    perform set_config('app.interno', 'sim', true);
    update public.orcamentos set status = 'convertido', venda_id = v_venda where id = v_orc.id;
  end if;
  return v_venda;
end $$;

-- Cancela a venda e devolve os produtos ao estoque
create or replace function public.cancelar_venda(p_venda uuid, p_motivo text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v record; r record;
begin
  select * into v from public.vendas where id = p_venda and empresa_id = public.minha_empresa() for update;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if v.status = 'cancelada' then raise exception 'Esta venda já está cancelada.'; end if;
  for r in select produto_id, sum(quantidade) q from public.venda_itens
            where venda_id = p_venda and tipo = 'produto' and produto_id is not null group by produto_id loop
    insert into public.movimentacoes_estoque (produto_id, tipo, delta, venda_id, observacao)
    values (r.produto_id, 'cancelamento_venda', r.q, p_venda, 'Cancelamento da venda nº ' || v.numero);
  end loop;
  update public.vendas set status = 'cancelada', cancelada_em = now(), motivo_cancelamento = coalesce(p_motivo,'')
   where id = p_venda;
  if v.orcamento_id is not null then
    perform set_config('app.interno', 'sim', true);
    update public.orcamentos set status = 'aprovado', venda_id = null where id = v.orcamento_id;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 5b. ORÇAMENTOS E PAGAMENTOS (v3)
-- ---------------------------------------------------------------------

-- Protege a situação do orçamento: "convertido" só por meio da venda
create or replace function public.tg_orcamento_status() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.interno', true), '') = 'sim' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'convertido' then
    raise exception 'Este orçamento já foi convertido em venda e não pode ser alterado.';
  end if;
  if new.status = 'convertido' or new.venda_id is not null then
    raise exception 'Para converter, use "Converter em venda".';
  end if;
  return new;
end $$;
drop trigger if exists orcamento_status on public.orcamentos;
create trigger orcamento_status before insert or update on public.orcamentos
  for each row execute function public.tg_orcamento_status();

-- Cria ou altera um orçamento com seus itens (preços do cadastro no momento) — tudo ou nada
-- p = {id?, cliente_id, itens:[{tipo,id,quantidade}], desconto_tipo, desconto_valor, validade, observacao, status?}
create or replace function public.salvar_orcamento(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_emp uuid := public.minha_empresa(); v_id uuid := (p->>'id')::uuid; v_old record;
  v_cli_id uuid; v_cli_nome text; it jsonb; r record; v_sub numeric := 0;
  v_dtipo text := coalesce(p->>'desconto_tipo','valor'); v_dval numeric := coalesce((p->>'desconto_valor')::numeric,0);
  v_status text := coalesce(nullif(p->>'status',''), 'aberto');
begin
  if v_emp is null then raise exception 'Usuário sem empresa.'; end if;
  if v_status not in ('aberto','enviado','aprovado','recusado') then raise exception 'Situação inválida.'; end if;
  if v_dtipo not in ('valor','percentual') or v_dval < 0 then raise exception 'Desconto inválido.'; end if;
  if jsonb_array_length(coalesce(p->'itens','[]'::jsonb)) = 0 then raise exception 'Adicione ao menos um item.'; end if;
  select id, nome into v_cli_id, v_cli_nome from public.clientes where id = (p->>'cliente_id')::uuid and empresa_id = v_emp;
  perform set_config('app.interno', 'sim', true);
  if v_id is not null then
    select * into v_old from public.orcamentos where id = v_id and empresa_id = v_emp for update;
    if not found then raise exception 'Orçamento não encontrado.'; end if;
    if v_old.status = 'convertido' then raise exception 'Este orçamento já foi convertido em venda e não pode ser alterado.'; end if;
    delete from public.orcamento_itens where orcamento_id = v_id;
    update public.orcamentos set cliente_id = v_cli_id, cliente_nome = coalesce(v_cli_nome,''), validade = (p->>'validade')::date,
           desconto_tipo = v_dtipo, desconto_valor = v_dval, observacao = coalesce(p->>'observacao',''), status = v_status
     where id = v_id;
  else
    insert into public.orcamentos (cliente_id, cliente_nome, validade, desconto_tipo, desconto_valor, observacao, status)
    values (v_cli_id, coalesce(v_cli_nome,''), (p->>'validade')::date, v_dtipo, v_dval, coalesce(p->>'observacao',''), v_status)
    returning id into v_id;
  end if;
  for it in select * from jsonb_array_elements(p->'itens') loop
    if coalesce((it->>'quantidade')::numeric,0) <= 0 then raise exception 'Quantidade inválida.'; end if;
    if it->>'tipo' = 'produto' then
      select id, nome, especificacao, categoria, preco_venda as preco, custo into r from public.produtos where id = (it->>'id')::uuid and empresa_id = v_emp;
    else
      select id, nome, especificacao, categoria, preco, 0::numeric as custo into r from public.servicos where id = (it->>'id')::uuid and empresa_id = v_emp;
    end if;
    if not found then raise exception 'Item não encontrado.'; end if;
    insert into public.orcamento_itens (orcamento_id, tipo, produto_id, servico_id, descricao, especificacao, categoria, quantidade, preco_unitario, custo_unitario, total)
    values (v_id, it->>'tipo', case when it->>'tipo'='produto' then r.id end, case when it->>'tipo'='servico' then r.id end,
            r.nome, r.especificacao, r.categoria, (it->>'quantidade')::numeric, r.preco, r.custo, round(r.preco * (it->>'quantidade')::numeric, 2));
    v_sub := v_sub + round(r.preco * (it->>'quantidade')::numeric, 2);
  end loop;
  update public.orcamentos set subtotal = v_sub, desconto_total = public.calc_desconto(v_sub, v_dtipo, v_dval),
         total = v_sub - public.calc_desconto(v_sub, v_dtipo, v_dval) where id = v_id;
  return v_id;
end $$;

-- Registra um recebimento (total ou parcial) em uma parcela
create or replace function public.registrar_pagamento(p_parcela uuid, p_valor numeric, p_data date default current_date, p_forma text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select pa.*, ve.status as venda_status into v from public.parcelas pa join public.vendas ve on ve.id = pa.venda_id
   where pa.id = p_parcela and pa.empresa_id = public.minha_empresa() for update of pa;
  if not found then raise exception 'Parcela não encontrada.'; end if;
  if v.venda_status = 'cancelada' then raise exception 'Esta venda foi cancelada.'; end if;
  if coalesce(p_valor,0) <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if p_valor > v.valor - v.valor_pago + 0.001 then
    raise exception 'O valor informado é maior que o saldo da parcela (R$ %).', replace(to_char(v.valor - v.valor_pago, 'FM999999990.00'), '.', ',');
  end if;
  update public.parcelas set valor_pago = valor_pago + round(p_valor,2), pago_em = coalesce(p_data, current_date),
         forma_pagamento = coalesce(nullif(p_forma,''), forma_pagamento)
   where id = p_parcela;
end $$;

create or replace function public.estornar_pagamento(p_parcela uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sou_admin() then raise exception 'Somente administradores podem estornar pagamentos.'; end if;
  update public.parcelas set valor_pago = 0, pago_em = null where id = p_parcela and empresa_id = public.minha_empresa();
  if not found then raise exception 'Parcela não encontrada.'; end if;
end $$;

revoke execute on function public.salvar_orcamento(jsonb), public.registrar_pagamento(uuid,numeric,date,text),
                           public.estornar_pagamento(uuid) from anon;


-- ---------------------------------------------------------------------
-- 5c. HISTÓRICO DE PREÇOS E PREFERÊNCIAS (v4)
-- ---------------------------------------------------------------------
alter table public.empresas add column if not exists preferencias jsonb not null default '{}'::jsonb;
alter table public.produtos add column if not exists motivo_alteracao text;
alter table public.servicos add column if not exists motivo_alteracao text;

create table if not exists public.historico_precos (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references public.empresas(id) on delete cascade,
  tipo              text not null check (tipo in ('produto','servico')),
  produto_id        uuid references public.produtos(id) on delete set null,
  servico_id        uuid references public.servicos(id) on delete set null,
  nome              text not null default '',
  especificacao     text not null default '',
  materiais         jsonb not null default '[]'::jsonb,
  custo_materiais   numeric(14,2) not null default 0,
  valor_hora        numeric(14,2) not null default 0,
  horas_trabalhadas numeric(10,2) not null default 0,
  custo_horas       numeric(14,2) not null default 0,
  custo             numeric(14,2) not null default 0,
  lucro_percentual  numeric(9,2)  not null default 0,
  preco             numeric(14,2) not null default 0,
  preco_anterior    numeric(14,2),
  motivo            text not null default '',
  alterado_em       timestamptz not null default now(),
  usuario_id        uuid default auth.uid()
);
create index if not exists hist_produto on public.historico_precos (produto_id, alterado_em desc);
create index if not exists hist_servico on public.historico_precos (servico_id, alterado_em desc);

-- Guarda o motivo informado na tela (coluna transitória) para o registro do histórico
create or replace function public.tg_motivo_preco() returns trigger
language plpgsql as $$
begin
  perform set_config('app.motivo_preco', coalesce(trim(new.motivo_alteracao), ''), true);
  new.motivo_alteracao := null;
  return new;
end $$;
drop trigger if exists produto_zz_historico on public.produtos;
drop trigger if exists servico_zz_historico on public.servicos;
drop trigger if exists produto_zz_motivo on public.produtos;
create trigger produto_zz_motivo before insert or update on public.produtos for each row execute function public.tg_motivo_preco();
drop trigger if exists servico_zz_motivo on public.servicos;
create trigger servico_zz_motivo before insert or update on public.servicos for each row execute function public.tg_motivo_preco();

-- Registra o preço a cada cadastro ou alteração de valores
create or replace function public.tg_produto_historico() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_motivo text := coalesce(nullif(current_setting('app.motivo_preco', true), ''), case when tg_op = 'INSERT' then 'Cadastro inicial' else '' end);
begin
  if tg_op = 'UPDATE' and new.preco_venda = old.preco_venda and new.custo_materiais = old.custo_materiais
     and new.custo_horas = old.custo_horas and new.lucro_percentual = old.lucro_percentual then
    return null;
  end if;
  insert into public.historico_precos (empresa_id, tipo, produto_id, nome, especificacao, materiais, custo_materiais, valor_hora,
         horas_trabalhadas, custo_horas, custo, lucro_percentual, preco, preco_anterior, motivo)
  values (new.empresa_id, 'produto', new.id, new.nome, new.especificacao, new.materiais, new.custo_materiais, new.valor_hora,
         new.horas_trabalhadas, new.custo_horas, new.custo, new.lucro_percentual, new.preco_venda,
         case when tg_op = 'UPDATE' then old.preco_venda end, v_motivo);
  return null;
end $$;
drop trigger if exists produto_historico on public.produtos;
create trigger produto_historico after insert or update on public.produtos
  for each row execute function public.tg_produto_historico();

create or replace function public.tg_servico_historico() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_motivo text := coalesce(nullif(current_setting('app.motivo_preco', true), ''), case when tg_op = 'INSERT' then 'Cadastro inicial' else '' end);
begin
  if tg_op = 'UPDATE' and new.valor_hora = old.valor_hora and new.horas_trabalhadas = old.horas_trabalhadas then return null; end if;
  insert into public.historico_precos (empresa_id, tipo, servico_id, nome, especificacao, valor_hora, horas_trabalhadas, custo_horas,
         custo, preco, preco_anterior, motivo)
  values (new.empresa_id, 'servico', new.id, new.nome, new.especificacao, new.valor_hora, new.horas_trabalhadas, new.preco,
         0, new.preco, case when tg_op = 'UPDATE' then old.preco end, v_motivo);
  return null;
end $$;
drop trigger if exists servico_historico on public.servicos;
create trigger servico_historico after insert or update on public.servicos
  for each row execute function public.tg_servico_historico();

-- Produtos e serviços já cadastrados antes desta versão ganham o registro do preço atual
insert into public.historico_precos (empresa_id, tipo, produto_id, nome, especificacao, materiais, custo_materiais, valor_hora,
       horas_trabalhadas, custo_horas, custo, lucro_percentual, preco, motivo, alterado_em)
select p.empresa_id, 'produto', p.id, p.nome, p.especificacao, p.materiais, p.custo_materiais, p.valor_hora, p.horas_trabalhadas,
       p.custo_horas, p.custo, p.lucro_percentual, p.preco_venda, 'Preço vigente ao ativar o histórico', p.atualizado_em
  from public.produtos p where not exists (select 1 from public.historico_precos h where h.produto_id = p.id);
insert into public.historico_precos (empresa_id, tipo, servico_id, nome, especificacao, valor_hora, horas_trabalhadas, custo_horas,
       custo, preco, motivo, alterado_em)
select s.empresa_id, 'servico', s.id, s.nome, s.especificacao, s.valor_hora, s.horas_trabalhadas, s.preco, 0, s.preco,
       'Preço vigente ao ativar o histórico', s.atualizado_em
  from public.servicos s where not exists (select 1 from public.historico_precos h where h.servico_id = s.id);

alter table public.historico_precos enable row level security;
drop policy if exists hist_ler on public.historico_precos;
create policy hist_ler on public.historico_precos for select to authenticated using (empresa_id = public.minha_empresa());
revoke insert, update, delete on public.historico_precos from authenticated, anon;

-- ---------------------------------------------------------------------
-- 6. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
alter table public.empresas               enable row level security;
alter table public.membros                enable row level security;
alter table public.fornecedores           enable row level security;
alter table public.clientes               enable row level security;
alter table public.produtos               enable row level security;
alter table public.servicos               enable row level security;
alter table public.orcamentos             enable row level security;
alter table public.orcamento_itens        enable row level security;
alter table public.vendas                 enable row level security;
alter table public.venda_itens            enable row level security;
alter table public.parcelas               enable row level security;
alter table public.movimentacoes_estoque  enable row level security;

-- Empresa: membros leem; só admin altera
drop policy if exists empresa_ler on public.empresas;
create policy empresa_ler on public.empresas for select to authenticated using (id = public.minha_empresa());
drop policy if exists empresa_alterar on public.empresas;
create policy empresa_alterar on public.empresas for update to authenticated
  using (id = public.minha_empresa() and public.sou_admin()) with check (id = public.minha_empresa());

drop policy if exists membros_ler on public.membros;
create policy membros_ler on public.membros for select to authenticated using (empresa_id = public.minha_empresa());

-- Cadastros e operações: membros leem, incluem e alteram; só admin exclui
do $$ declare t text; begin
  foreach t in array array['fornecedores','clientes','produtos','servicos','orcamentos','orcamento_itens'] loop
    execute format('drop policy if exists %I on public.%I', t||'_ler', t);
    execute format('create policy %I on public.%I for select to authenticated using (empresa_id = public.minha_empresa())', t||'_ler', t);
    execute format('drop policy if exists %I on public.%I', t||'_incluir', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (empresa_id = public.minha_empresa())', t||'_incluir', t);
    execute format('drop policy if exists %I on public.%I', t||'_alterar', t);
    execute format('create policy %I on public.%I for update to authenticated using (empresa_id = public.minha_empresa()) with check (empresa_id = public.minha_empresa())', t||'_alterar', t);
    execute format('drop policy if exists %I on public.%I', t||'_excluir', t);
    execute format('create policy %I on public.%I for delete to authenticated using (empresa_id = public.minha_empresa() and (public.sou_admin() or %L in (''orcamento_itens'')))', t||'_excluir', t, t);
  end loop;
end $$;

-- Vendas e itens: incluídos pela função registrar_venda; nunca excluídos (somente cancelados)
drop policy if exists vendas_ler on public.vendas;
create policy vendas_ler on public.vendas for select to authenticated using (empresa_id = public.minha_empresa());
drop policy if exists vendas_incluir on public.vendas;
create policy vendas_incluir on public.vendas for insert to authenticated with check (empresa_id = public.minha_empresa());
drop policy if exists vendas_alterar on public.vendas;
create policy vendas_alterar on public.vendas for update to authenticated
  using (empresa_id = public.minha_empresa()) with check (empresa_id = public.minha_empresa());

drop policy if exists venda_itens_ler on public.venda_itens;
create policy venda_itens_ler on public.venda_itens for select to authenticated using (empresa_id = public.minha_empresa());
drop policy if exists venda_itens_incluir on public.venda_itens;
create policy venda_itens_incluir on public.venda_itens for insert to authenticated with check (empresa_id = public.minha_empresa());

-- Parcelas: leitura, inclusão e registro de pagamento
drop policy if exists parcelas_ler on public.parcelas;
create policy parcelas_ler on public.parcelas for select to authenticated using (empresa_id = public.minha_empresa());
drop policy if exists parcelas_incluir on public.parcelas;
create policy parcelas_incluir on public.parcelas for insert to authenticated with check (empresa_id = public.minha_empresa());
drop policy if exists parcelas_alterar on public.parcelas;
create policy parcelas_alterar on public.parcelas for update to authenticated
  using (empresa_id = public.minha_empresa()) with check (empresa_id = public.minha_empresa());

-- Movimentações: somente leitura e inclusão (histórico preservado)
drop policy if exists mov_ler on public.movimentacoes_estoque;
create policy mov_ler on public.movimentacoes_estoque for select to authenticated using (empresa_id = public.minha_empresa());
drop policy if exists mov_incluir on public.movimentacoes_estoque;
create policy mov_incluir on public.movimentacoes_estoque for insert to authenticated with check (empresa_id = public.minha_empresa());

-- Campos que não podem ser alterados diretamente pela tela
revoke update on public.vendas from authenticated;
grant  update (recibo_url, observacao) on public.vendas to authenticated;
revoke update on public.movimentacoes_estoque from authenticated;
revoke update on public.parcelas from authenticated;
grant  update (vencimento, observacao) on public.parcelas to authenticated;
revoke delete on public.movimentacoes_estoque, public.venda_itens, public.vendas, public.parcelas from authenticated;

revoke execute on function public.registrar_venda(jsonb), public.cancelar_venda(uuid,text) from anon;
revoke execute on function public.criar_minha_empresa(text), public.listar_membros(),
                           public.adicionar_membro(text,text), public.remover_membro(uuid) from anon;

-- ---------------------------------------------------------------------
-- 7. STORAGE (fotos e documentos) — pasta = id da empresa
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('fotos', 'fotos', true), ('documentos', 'documentos', false)
on conflict (id) do nothing;

drop policy if exists "gestao_arquivos_ler" on storage.objects;
create policy "gestao_arquivos_ler" on storage.objects for select to authenticated
  using (bucket_id in ('fotos','documentos') and (storage.foldername(name))[1] = public.minha_empresa()::text);
drop policy if exists "gestao_arquivos_incluir" on storage.objects;
create policy "gestao_arquivos_incluir" on storage.objects for insert to authenticated
  with check (bucket_id in ('fotos','documentos') and (storage.foldername(name))[1] = public.minha_empresa()::text);
drop policy if exists "gestao_arquivos_alterar" on storage.objects;
create policy "gestao_arquivos_alterar" on storage.objects for update to authenticated
  using (bucket_id in ('fotos','documentos') and (storage.foldername(name))[1] = public.minha_empresa()::text);
drop policy if exists "gestao_arquivos_excluir" on storage.objects;
create policy "gestao_arquivos_excluir" on storage.objects for delete to authenticated
  using (bucket_id in ('fotos','documentos') and (storage.foldername(name))[1] = public.minha_empresa()::text);

-- FIM
