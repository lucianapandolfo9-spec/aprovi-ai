-- =====================================================================
-- aprovi.ai — MIGRATION FUNDACIONAL do schema `posta_ai`
-- =====================================================================
--
-- EXTRAÍDO DO BANCO DE PRODUÇÃO (projeto tscnqvuzlfagotirgjbz) em 01/10/2026
-- por introspecção — pg_get_functiondef / pg_get_constraintdef / pg_attrdef /
-- pg_indexes / pg_class.relrowsecurity — NÃO escrito de memória.
--
-- ⚠️ ESTE ARQUIVO É O ESTADO ATUAL, NÃO UM HISTÓRICO.
-- O schema `posta_ai` foi construído entre 29/jul e 14/set/2026 por ~20
-- migrations aplicadas direto no banco via MCP, que nunca existiram como
-- arquivo. Aquelas migrations estão intercaladas cronologicamente com as de
-- dois outros sistemas (Certo Agro e Hub Luh Panda) que dividiam o mesmo
-- banco — então replayá-las contra um Postgres limpo não funciona: elas
-- referenciam objetos criados pelas migrations dos outros dois.
--
-- A resposta é esta: um retrato fiel do estado final. O histórico datado
-- NÃO é passo pendente. Nada aqui precisa ser aplicado em produção —
-- produção já ESTÁ neste estado. Este arquivo existe pra criar instâncias
-- NOVAS (ex.: a réplica na organização do Codex).
--
-- ORDEM INTERNA (não reordene sem pensar):
--   1. extensões
--   2. schema + grants
--   3. tabelas, em ordem topológica de FK
--   4. índices
--   5. RLS
--   6. funções — `posta_ai_is_admin` primeiro, porque as funções em
--      LANGUAGE sql são validadas no momento da criação e chamam ela
--   7. grants/revokes das funções
--
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. EXTENSÕES
-- ---------------------------------------------------------------------
-- pgcrypto  -> gen_random_bytes() no default de brands.secret_token e digest() no Vault
-- uuid-ossp -> histórico; gen_random_uuid() hoje é nativo do Postgres 13+
-- pg_cron / pg_net -> só pro agendador (migration 00000000000002). Opcionais
--                     numa réplica, onde o cron nasce desligado.
create extension if not exists pgcrypto   with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;


-- ---------------------------------------------------------------------
-- 2. SCHEMA
-- ---------------------------------------------------------------------
-- DECISÃO DE SEGURANÇA, não esquecimento: `posta_ai` NÃO recebe USAGE pra
-- anon nem authenticated, e NÃO é exposto via PostgREST. Em produção o ACL
-- do schema é exatamente {postgres=UC/postgres}.
-- Todo acesso passa por funções SECURITY DEFINER no schema `public`.
create schema if not exists posta_ai;

comment on schema posta_ai is
  'aprovi.ai — aprovação e publicação automática de conteúdo social. '
  'Não exposto via REST de propósito: acesso só por funções SECURITY DEFINER em public.';


-- ---------------------------------------------------------------------
-- 3. TABELAS (ordem topológica de FK)
-- ---------------------------------------------------------------------

create table posta_ai.workspaces (
  id uuid not null default gen_random_uuid(),
  nome text not null,
  criado_em timestamp with time zone not null default now(),
  constraint workspaces_pkey PRIMARY KEY (id)
);

create table posta_ai.brands (
  id uuid not null default gen_random_uuid(),
  workspace_id uuid not null,
  nome text not null,
  handle text,
  timezone text not null default 'America/Sao_Paulo'::text,
  idioma text not null default 'en'::text,
  -- secret_token é a ÚNICA credencial do portal do cliente (cliente.html não
  -- tem login — a autorização é este valor na query string). O default gera
  -- 24 bytes aleatórios em hex. Nunca escreva um literal aqui, em nenhum
  -- seed, em nenhum ambiente.
  secret_token text not null default encode(gen_random_bytes(24), 'hex'::text),
  criado_em timestamp with time zone not null default now(),
  constraint brands_pkey PRIMARY KEY (id),
  constraint brands_secret_token_key UNIQUE (secret_token),
  constraint brands_workspace_id_fkey FOREIGN KEY (workspace_id)
    REFERENCES posta_ai.workspaces(id) ON DELETE CASCADE
);

create table posta_ai.caption_blocks (
  id uuid not null default gen_random_uuid(),
  brand_id uuid not null,
  tipo text not null default 'assinatura_padrao'::text,
  conteudo text not null default ''::text,
  ativo boolean not null default true,
  atualizado_em timestamp with time zone not null default now(),
  constraint caption_blocks_pkey PRIMARY KEY (id),
  constraint caption_blocks_brand_id_fkey FOREIGN KEY (brand_id)
    REFERENCES posta_ai.brands(id) ON DELETE CASCADE
);

create table posta_ai.posts (
  id uuid not null default gen_random_uuid(),
  brand_id uuid not null,
  titulo_interno text,
  formato text not null default 'reel'::text,
  status text not null default 'rascunho'::text,
  agendado_para timestamp with time zone,
  criado_em timestamp with time zone not null default now(),
  atualizado_em timestamp with time zone not null default now(),
  -- post_origem_id  -> story COMPANHEIRO, gerado automaticamente D+1 depois
  --                    que um reel/feed publica (rpc_marcar_resultado_publicacao).
  -- story_rodizio_de -> story do RODÍZIO DIÁRIO, escolhido por
  --                    posta_ai.enfileirar_story_diario.
  -- As duas colunas são SEPARADAS DE PROPÓSITO: cada automação tem a própria
  -- guarda anti-duplicata e elas precisam ser independentes. Não unifique.
  post_origem_id uuid,
  story_rodizio_de uuid,
  constraint posts_pkey PRIMARY KEY (id),
  constraint posts_brand_id_fkey FOREIGN KEY (brand_id)
    REFERENCES posta_ai.brands(id) ON DELETE CASCADE,
  constraint posts_post_origem_id_fkey FOREIGN KEY (post_origem_id)
    REFERENCES posta_ai.posts(id),
  constraint posts_story_rodizio_de_fkey FOREIGN KEY (story_rodizio_de)
    REFERENCES posta_ai.posts(id),
  constraint posts_formato_check CHECK ((formato = ANY (ARRAY['reel'::text, 'feed'::text, 'story'::text, 'carrossel'::text]))),
  -- A máquina de estados inteira:
  --   rascunho -> em_aprovacao -> aprovado | ajuste_pedido
  --            -> agendado -> publicando -> publicado | falhou
  -- `ajuste_pedido` significa ESPECIFICAMENTE "precisa editar o vídeo".
  -- Mudança só de legenda nunca passa por aqui.
  constraint posts_status_check CHECK ((status = ANY (ARRAY['rascunho'::text, 'em_aprovacao'::text, 'ajuste_pedido'::text, 'aprovado'::text, 'agendado'::text, 'publicando'::text, 'publicado'::text, 'falhou'::text])))
);

create table posta_ai.post_assets (
  id uuid not null default gen_random_uuid(),
  post_id uuid not null,
  ordem integer not null default 0,
  tipo text not null default 'video'::text,
  url text not null,
  thumb_url text,
  duracao_seg numeric,
  constraint post_assets_pkey PRIMARY KEY (id),
  constraint post_assets_post_id_fkey FOREIGN KEY (post_id)
    REFERENCES posta_ai.posts(id) ON DELETE CASCADE,
  constraint post_assets_tipo_check CHECK ((tipo = ANY (ARRAY['video'::text, 'imagem'::text])))
);

create table posta_ai.post_captions (
  id uuid not null default gen_random_uuid(),
  post_id uuid not null,
  versao integer not null default 1,
  corpo text not null default ''::text,
  -- 'auto' existe pra legenda copiada por automação (story companheiro e
  -- rodízio diário). Sem ele o insert automático violaria o check.
  autor text not null default 'editor'::text,
  criado_em timestamp with time zone not null default now(),
  constraint post_captions_pkey PRIMARY KEY (id),
  constraint post_captions_post_id_fkey FOREIGN KEY (post_id)
    REFERENCES posta_ai.posts(id) ON DELETE CASCADE,
  constraint post_captions_autor_check CHECK ((autor = ANY (ARRAY['editor'::text, 'aprovador'::text, 'auto'::text])))
);

create table posta_ai.post_comments (
  -- Feedback do fluxo de aprovação. NÃO é comentário do Instagram.
  id uuid not null default gen_random_uuid(),
  post_id uuid not null,
  autor text not null default 'aprovador'::text,
  texto text not null,
  criado_em timestamp with time zone not null default now(),
  constraint post_comments_pkey PRIMARY KEY (id),
  constraint post_comments_post_id_fkey FOREIGN KEY (post_id)
    REFERENCES posta_ai.posts(id) ON DELETE CASCADE
);

create table posta_ai.post_events (
  id uuid not null default gen_random_uuid(),
  post_id uuid not null,
  de_status text,
  para_status text not null,
  autor text not null,
  criado_em timestamp with time zone not null default now(),
  constraint post_events_pkey PRIMARY KEY (id),
  constraint post_events_post_id_fkey FOREIGN KEY (post_id)
    REFERENCES posta_ai.posts(id) ON DELETE CASCADE
);

create table posta_ai.publish_jobs (
  id uuid not null default gen_random_uuid(),
  post_id uuid not null,
  tentativa integer not null default 1,
  ig_creation_id text,
  ig_media_id text,
  status text not null default 'pendente'::text,
  erro text,
  criado_em timestamp with time zone not null default now(),
  publicado_em timestamp with time zone,
  constraint publish_jobs_pkey PRIMARY KEY (id),
  -- ⚠️ SEM ON DELETE — reproduz produção fielmente. Ver "DÉBITO CONHECIDO"
  -- no fim deste arquivo: é a causa do bug de exclusão de post.
  constraint publish_jobs_post_id_fkey FOREIGN KEY (post_id)
    REFERENCES posta_ai.posts(id),
  constraint publish_jobs_status_check CHECK ((status = ANY (ARRAY['pendente'::text, 'em_andamento'::text, 'publicado'::text, 'falhou'::text])))
);

create table posta_ai.social_accounts (
  id uuid not null default gen_random_uuid(),
  brand_id uuid not null,
  ig_user_id text not null,
  page_id text not null,
  ad_account_id text,
  -- token_secret_id aponta pro Vault. O token da Meta NUNCA é guardado cru
  -- nesta tabela. Quem decripta é rpc_proximo_post_agendado, que roda como
  -- SECURITY DEFINER e só pode ser chamada por service_role.
  token_secret_id uuid not null,
  meta_app_id text,
  permissoes text[],
  expira_em timestamp with time zone,
  conectado_em timestamp with time zone not null default now(),
  atualizado_em timestamp with time zone not null default now(),
  constraint social_accounts_pkey PRIMARY KEY (id),
  constraint social_accounts_brand_id_fkey FOREIGN KEY (brand_id)
    REFERENCES posta_ai.brands(id)
);


-- ---------------------------------------------------------------------
-- 4. ÍNDICES
-- ---------------------------------------------------------------------
-- Índice parcial: o agendador só procura post 'agendado'. Os outros índices
-- do schema são os implícitos de PK/UNIQUE, criados acima.
CREATE INDEX idx_posts_agendado_para ON posta_ai.posts USING btree (agendado_para)
  WHERE (status = 'agendado'::text);


-- ---------------------------------------------------------------------
-- 5. RLS — ligado em todas as 10, com ZERO POLICIES
-- ---------------------------------------------------------------------
-- ⚠️ LEIA ANTES DE "CONSERTAR": a ausência de policy é o desenho, não lacuna.
-- RLS ligado + nenhuma policy = NEGA TUDO pra qualquer role que não seja
-- superuser ou owner. Combinado com o schema sem USAGE pra anon/authenticated,
-- o resultado é que nenhuma tabela daqui é alcançável por API, nunca.
-- O acesso legítimo é 100% via funções SECURITY DEFINER em `public`, que
-- carregam a autorização dentro delas.
--
-- Se um dia aparecer uma policy aqui, isso é REGRESSÃO — o script de
-- verificação afirma que a contagem é 0.
alter table posta_ai.workspaces      enable row level security;
alter table posta_ai.brands          enable row level security;
alter table posta_ai.caption_blocks  enable row level security;
alter table posta_ai.posts           enable row level security;
alter table posta_ai.post_assets     enable row level security;
alter table posta_ai.post_captions   enable row level security;
alter table posta_ai.post_comments   enable row level security;
alter table posta_ai.post_events     enable row level security;
alter table posta_ai.publish_jobs    enable row level security;
alter table posta_ai.social_accounts enable row level security;


-- =====================================================================
-- 6. FUNÇÕES — 22 no total
-- =====================================================================
-- 1 em posta_ai  : enfileirar_story_diario
-- 18 em public   : posta_ai_*
-- 3 em public    : rpc_* SEM o prefixo posta_ai_ — ARMADILHA CONHECIDA.
--                  rpc_proximo_post_agendado, rpc_marcar_resultado_publicacao,
--                  rpc_validar_upload. Qualquer filtro por prefixo
--                  'posta_ai%' derruba as três em silêncio: a réplica aplica
--                  limpa, deploya limpa, e só morre quando um post vence.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6.1 Guarda de admin — PRIMEIRO, porque as funções LANGUAGE sql abaixo
--     são validadas na criação e chamam esta.
-- ---------------------------------------------------------------------
-- 🔴 O `coalesce` NÃO é estilo, é correção de vulnerabilidade.
-- Em 29/jul/2026 esta função era `auth.email() = '...'`. Quando não há
-- sessão, auth.email() devolve NULL, e `NULL = 'x'` é NULL — que não é
-- false. Em PL/pgSQL `if not NULL then` não entra no bloco, então TODA
-- função admin passava sem login. O coalesce fecha isso.
-- Ao portar: copie, não redigite.
--
-- E-mail literal de propósito: hoje o aprovi.ai é single-admin.
-- Consequência numa réplica: quem não tiver este e-mail não consegue
-- exercitar a UI de admin. Use service_role pra isso. O caminho do
-- cliente (por token) funciona inteiro.
CREATE OR REPLACE FUNCTION public.posta_ai_is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(auth.email(), '') = 'lucianapandolfo9@gmail.com';
$function$
;

-- ---------------------------------------------------------------------
-- 6.2 Porta do cliente — autorização por token na URL, sem login
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.posta_ai_brand_from_token(p_token text)
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
  select id from posta_ai.brands where secret_token = p_token;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_client_feed(p_token text)
 RETURNS TABLE(id uuid, titulo_interno text, formato text, status text, agendado_para timestamp with time zone, criado_em timestamp with time zone, assinatura_padrao text, legenda_atual text, assets jsonb, comentarios jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_brand uuid;
begin
  v_brand := public.posta_ai_brand_from_token(p_token);
  if v_brand is null then raise exception 'invalid token'; end if;

  return query
  select
    p.id, p.titulo_interno, p.formato, p.status, p.agendado_para, p.criado_em,
    (select cb.conteudo from posta_ai.caption_blocks cb where cb.brand_id = v_brand and cb.ativo order by cb.atualizado_em desc limit 1),
    (select pc.corpo from posta_ai.post_captions pc where pc.post_id = p.id order by pc.versao desc limit 1),
    (select coalesce(jsonb_agg(jsonb_build_object('url', pa.url, 'thumb', pa.thumb_url, 'tipo', pa.tipo, 'ordem', pa.ordem, 'duracao', pa.duracao_seg) order by pa.ordem), '[]'::jsonb)
       from posta_ai.post_assets pa where pa.post_id = p.id),
    (select coalesce(jsonb_agg(jsonb_build_object('autor', c.autor, 'texto', c.texto, 'criado_em', c.criado_em) order by c.criado_em), '[]'::jsonb)
       from posta_ai.post_comments c where c.post_id = p.id)
  from posta_ai.posts p
  where p.brand_id = v_brand and p.status <> 'rascunho'
  order by p.criado_em desc;
end;
$function$
;

-- O cliente pode editar a legenda E aprovar na MESMA ação: p_legenda vem
-- junto da decisão e entra como nova versão com autor='aprovador'.
-- Por isso mudança de legenda não precisa passar por 'ajuste_pedido'.
CREATE OR REPLACE FUNCTION public.posta_ai_client_decide(p_token text, p_post_id uuid, p_decisao text, p_comentario text DEFAULT NULL::text, p_legenda text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_brand uuid; v_post_brand uuid; v_old_status text;
begin
  v_brand := public.posta_ai_brand_from_token(p_token);
  if v_brand is null then raise exception 'invalid token'; end if;
  if p_decisao not in ('aprovado','ajuste_pedido') then raise exception 'invalid decision'; end if;

  select brand_id, status into v_post_brand, v_old_status from posta_ai.posts where id = p_post_id;
  if v_post_brand is null or v_post_brand <> v_brand then raise exception 'post not found for this brand'; end if;

  if p_legenda is not null and length(trim(p_legenda)) > 0 then
    insert into posta_ai.post_captions (post_id, versao, corpo, autor)
    values (p_post_id, coalesce((select max(versao) from posta_ai.post_captions where post_id = p_post_id),0)+1, p_legenda, 'aprovador');
  end if;

  if p_comentario is not null and length(trim(p_comentario)) > 0 then
    insert into posta_ai.post_comments (post_id, autor, texto) values (p_post_id, 'aprovador', p_comentario);
  end if;

  update posta_ai.posts set status = p_decisao, atualizado_em = now() where id = p_post_id;
  insert into posta_ai.post_events (post_id, de_status, para_status, autor) values (p_post_id, v_old_status, p_decisao, 'aprovador');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_client_update_signature(p_token text, p_conteudo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_brand uuid;
begin
  v_brand := public.posta_ai_brand_from_token(p_token);
  if v_brand is null then raise exception 'invalid token'; end if;

  update posta_ai.caption_blocks
  set conteudo = p_conteudo, atualizado_em = now()
  where brand_id = v_brand and ativo;
end;
$function$
;

-- ---------------------------------------------------------------------
-- 6.3 Painel da Luciana (admin)
-- ---------------------------------------------------------------------
-- Padrão: as plpgsql levantam 'forbidden'; as LANGUAGE sql põem
-- posta_ai_is_admin() dentro do WHERE (sem admin, zero linha).
CREATE OR REPLACE FUNCTION public.posta_ai_admin_list_brands()
 RETURNS SETOF posta_ai.brands
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
  select b.* from posta_ai.brands b
  where public.posta_ai_is_admin()
  order by b.criado_em desc;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_create_brand(p_workspace_nome text, p_nome text, p_handle text, p_timezone text, p_idioma text, p_assinatura text)
 RETURNS posta_ai.brands
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_ws uuid; v_brand posta_ai.brands;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;

  select id into v_ws from posta_ai.workspaces where nome = p_workspace_nome limit 1;
  if v_ws is null then
    insert into posta_ai.workspaces (nome) values (p_workspace_nome) returning id into v_ws;
  end if;

  insert into posta_ai.brands (workspace_id, nome, handle, timezone, idioma)
  values (v_ws, p_nome, p_handle, coalesce(p_timezone,'America/Sao_Paulo'), coalesce(p_idioma,'en'))
  returning * into v_brand;

  insert into posta_ai.caption_blocks (brand_id, tipo, conteudo, ativo)
  values (v_brand.id, 'assinatura_padrao', coalesce(p_assinatura,''), true);

  return v_brand;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_delete_brand(p_brand_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;

  delete from posta_ai.publish_jobs
  where post_id in (select id from posta_ai.posts where brand_id = p_brand_id);

  delete from posta_ai.post_events
  where post_id in (select id from posta_ai.posts where brand_id = p_brand_id);

  delete from posta_ai.post_comments
  where post_id in (select id from posta_ai.posts where brand_id = p_brand_id);

  delete from posta_ai.post_captions
  where post_id in (select id from posta_ai.posts where brand_id = p_brand_id);

  delete from posta_ai.post_assets
  where post_id in (select id from posta_ai.posts where brand_id = p_brand_id);

  delete from posta_ai.posts where brand_id = p_brand_id;
  delete from posta_ai.social_accounts where brand_id = p_brand_id;
  delete from posta_ai.caption_blocks where brand_id = p_brand_id;
  delete from posta_ai.brands where id = p_brand_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_list_posts(p_brand_id uuid)
 RETURNS TABLE(id uuid, titulo_interno text, formato text, status text, agendado_para timestamp with time zone, criado_em timestamp with time zone, legenda_atual text, assets jsonb, comentarios jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
  select
    p.id, p.titulo_interno, p.formato, p.status, p.agendado_para, p.criado_em,
    (select corpo from posta_ai.post_captions pc where pc.post_id = p.id order by pc.versao desc limit 1),
    (select coalesce(jsonb_agg(jsonb_build_object('url', pa.url, 'thumb', pa.thumb_url, 'tipo', pa.tipo, 'ordem', pa.ordem, 'duracao', pa.duracao_seg) order by pa.ordem), '[]'::jsonb)
       from posta_ai.post_assets pa where pa.post_id = p.id),
    (select coalesce(jsonb_agg(jsonb_build_object('autor', c.autor, 'texto', c.texto, 'criado_em', c.criado_em) order by c.criado_em), '[]'::jsonb)
       from posta_ai.post_comments c where c.post_id = p.id)
  from posta_ai.posts p
  where p.brand_id = p_brand_id and public.posta_ai_is_admin()
  order by p.criado_em desc;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_create_post(p_brand_id uuid, p_titulo text, p_formato text, p_legenda text, p_assets jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_post uuid; v_asset jsonb;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;

  insert into posta_ai.posts (brand_id, titulo_interno, formato, status)
  values (p_brand_id, p_titulo, coalesce(p_formato,'reel'), 'rascunho')
  returning id into v_post;

  insert into posta_ai.post_captions (post_id, versao, corpo, autor)
  values (v_post, 1, coalesce(p_legenda,''), 'editor');

  for v_asset in select * from jsonb_array_elements(coalesce(p_assets,'[]'::jsonb))
  loop
    insert into posta_ai.post_assets (post_id, ordem, tipo, url, thumb_url, duracao_seg)
    values (
      v_post,
      coalesce((v_asset->>'ordem')::int, 0),
      coalesce(v_asset->>'tipo','video'),
      v_asset->>'url',
      v_asset->>'thumb_url',
      nullif(v_asset->>'duracao','')::numeric
    );
  end loop;

  insert into posta_ai.post_events (post_id, de_status, para_status, autor)
  values (v_post, null, 'rascunho', 'editor');

  return v_post;
end;
$function$
;

-- 📌 CORRIGIDO em 01/10/2026. A versão anterior fazia um
-- `delete from posta_ai.posts` seco e falhava por violação de FK em
-- **36 de 40 posts** em produção: `publish_jobs_post_id_fkey`,
-- `posts_post_origem_id_fkey` e `posts_story_rodizio_de_fkey` não têm
-- cláusula ON DELETE. Só os 4 posts que nunca publicaram nem geraram story
-- derivado eram deletáveis.
--
-- Cobertura verificada: exatamente 7 FKs apontam pra posta_ai.posts —
-- 4 são CASCADE (post_assets, post_captions, post_comments, post_events,
-- caem sozinhas) e 3 bloqueiam, e as 3 são tratadas aqui.
CREATE OR REPLACE FUNCTION public.posta_ai_admin_delete_post(p_post_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;

  -- Stories derivados: DESVINCULA, não apaga.
  -- O story derivado é um post separado, aparece no kanban e pode já ter
  -- publicado no Instagram — apagar junto seria surpresa pra quem clicou em
  -- "excluir" num reel. Perder o vínculo não custa nada: a guarda
  -- anti-duplicata que ele servia só importa enquanto o post de origem existe.
  update posta_ai.posts set post_origem_id   = null where post_origem_id   = p_post_id;
  update posta_ai.posts set story_rodizio_de = null where story_rodizio_de = p_post_id;

  -- publish_jobs NÃO tem ON DELETE CASCADE — tem que sair na mão.
  delete from posta_ai.publish_jobs where post_id = p_post_id;

  -- post_assets, post_captions, post_comments e post_events TÊM
  -- ON DELETE CASCADE, então caem junto com o post. Não precisa listar.
  delete from posta_ai.posts where id = p_post_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_send_for_approval(p_post_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_old text;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  select status into v_old from posta_ai.posts where id = p_post_id;
  update posta_ai.posts set status = 'em_aprovacao', atualizado_em = now() where id = p_post_id;
  insert into posta_ai.post_events (post_id, de_status, para_status, autor) values (p_post_id, v_old, 'em_aprovacao', 'editor');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_set_schedule(p_post_id uuid, p_agendado_para timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_old text;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  select status into v_old from posta_ai.posts where id = p_post_id;
  update posta_ai.posts set status = 'agendado', agendado_para = p_agendado_para, atualizado_em = now() where id = p_post_id;
  insert into posta_ai.post_events (post_id, de_status, para_status, autor) values (p_post_id, v_old, 'agendado', 'editor');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_update_caption(p_post_id uuid, p_corpo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  insert into posta_ai.post_captions (post_id, versao, corpo, autor)
  values (p_post_id, coalesce((select max(versao) from posta_ai.post_captions where post_id = p_post_id),0)+1, p_corpo, 'editor');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_add_comment(p_post_id uuid, p_texto text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  insert into posta_ai.post_comments (post_id, autor, texto) values (p_post_id, 'editor', p_texto);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_get_caption_block(p_brand_id uuid)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
  select conteudo from posta_ai.caption_blocks
  where brand_id = p_brand_id and ativo and public.posta_ai_is_admin()
  order by atualizado_em desc limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_set_caption_block(p_brand_id uuid, p_conteudo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  update posta_ai.caption_blocks set conteudo = p_conteudo, atualizado_em = now()
  where brand_id = p_brand_id and ativo;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.posta_ai_admin_list_brand_asset_urls(p_brand_id uuid)
 RETURNS TABLE(url text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
  select pa.url
  from posta_ai.post_assets pa
  join posta_ai.posts p on p.id = pa.post_id
  where public.posta_ai_is_admin() and p.brand_id = p_brand_id;
$function$
;


-- ---------------------------------------------------------------------
-- 6.4 Rodízio diário de story — automação 100% em SQL
-- ---------------------------------------------------------------------
-- PADRÃO HOMOLOGADO: automação que só mexe em banco é função SQL + pg_cron.
-- Edge Function só quando precisa falar com o mundo de fora.
CREATE OR REPLACE FUNCTION posta_ai.enfileirar_story_diario(p_brand_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'posta_ai', 'public'
AS $function$
declare
  v_alvo      timestamptz;
  v_dia_alvo  date;
  v_fonte     record;
  v_story_id  uuid;
  v_corpo     text;
begin
  -- Proximo 12:00 de Los Angeles que ainda nao passou.
  -- Calculado por timezone nomeada, nao por offset fixo, entao o horario de
  -- verao (PDT -> PST em novembro) nao desloca a postagem.
  v_dia_alvo := (now() at time zone 'America/Los_Angeles')::date;
  v_alvo := (v_dia_alvo::text || ' 12:00')::timestamp at time zone 'America/Los_Angeles';
  if v_alvo <= now() then
    v_dia_alvo := v_dia_alvo + 1;
    v_alvo := (v_dia_alvo::text || ' 12:00')::timestamp at time zone 'America/Los_Angeles';
  end if;

  -- No maximo 1 story por dia. Cobre dois casos de uma vez:
  -- (a) o dia ja tem o story companheiro automatico do feed -> cede a vez pra ele;
  -- (b) o cron rodou duas vezes no mesmo dia -> idempotente, nao duplica.
  if exists (
    select 1
    from posta_ai.posts
    where brand_id = p_brand_id
      and formato = 'story'
      and status <> 'falhou'
      and agendado_para is not null
      and (agendado_para at time zone 'America/Los_Angeles')::date = v_dia_alvo
  ) then
    return null;
  end if;

  -- Escolhe o video elegivel que esta ha mais tempo sem ir pra story.
  -- Elegivel = post de feed/reel que a Gigi ja aprovou (aprovado/agendado/publicado).
  -- Quem esta em 'em_aprovacao' fica de fora sozinho, e entra sozinho quando ela aprovar.
  select p.id, p.titulo_interno, a.tipo, a.url, a.duracao_seg
  into v_fonte
  from posta_ai.posts p
  join posta_ai.post_assets a
    on a.post_id = p.id and a.ordem = 0
  where p.brand_id = p_brand_id
    and p.formato in ('reel', 'feed')
    and p.status in ('aprovado', 'agendado', 'publicado')
    and a.tipo = 'video'
  order by (
    select max(s.agendado_para)
    from posta_ai.posts s
    join posta_ai.post_assets sa on sa.post_id = s.id
    where s.brand_id = p_brand_id
      and s.formato = 'story'
      and s.status <> 'falhou'
      and sa.url = a.url
  ) asc nulls first,
  p.criado_em asc
  limit 1;

  if not found then
    return null;
  end if;

  insert into posta_ai.posts
    (brand_id, titulo_interno, formato, status, agendado_para, story_rodizio_de)
  values
    (p_brand_id,
     coalesce(v_fonte.titulo_interno, 'Story') || ' — Story (rodízio)',
     'story', 'agendado', v_alvo, v_fonte.id)
  returning id into v_story_id;

  insert into posta_ai.post_assets (post_id, ordem, tipo, url, duracao_seg)
  values (v_story_id, 0, v_fonte.tipo, v_fonte.url, v_fonte.duracao_seg);

  -- Instagram nao exibe legenda em story (a Edge Function omite o campo), mas
  -- copiar mantem o card do painel legivel pra Luciana e pra Gigi.
  select corpo into v_corpo
  from posta_ai.post_captions
  where post_id = v_fonte.id
  order by versao desc
  limit 1;

  if v_corpo is not null then
    insert into posta_ai.post_captions (post_id, versao, corpo, autor)
    values (v_story_id, 1, v_corpo, 'auto');
  end if;

  return v_story_id;
end;
$function$
;


-- =====================================================================
-- 6.5 As 3 RPCs SEM prefixo — só service_role
-- =====================================================================
-- 🔴 Estas três são a armadilha de nomenclatura do projeto. Não têm o
-- prefixo posta_ai_ mas são do aprovi.ai. Ver o aviso no topo da seção 6.
-- =====================================================================

-- 🔴 FUNÇÃO DE MAIOR PRIVILÉGIO DO SISTEMA.
-- Decripta o token da Meta do Vault e o DEVOLVE na coluna `token`.
-- Não tem — e não precisa ter — checagem de autorização interna: a defesa
-- é o grant. Ela só pode ser chamada por service_role, e a única coisa que
-- a chama é a Edge Function publicar-posts-agendados, que roda com
-- SUPABASE_SERVICE_ROLE_KEY injetada pelo runtime.
--
-- 🔴 INCIDENTE DE 01/10/2026 — LEIA ANTES DE MEXER:
-- Esta função esteve com EXECUTE concedido a PUBLIC, anon e authenticated.
-- Como a anon key é publicada no config.js deste repo (que é público),
-- qualquer pessoa podia fazer
--     POST /rest/v1/rpc/rpc_proximo_post_agendado  + apikey: <anon>
-- e receber o token da BM central da Luh Panda (expiração "never", cobre
-- Instagram, Página e Ads), além de roubar o próximo post agendado antes
-- do cron. Corrigido pela migration
-- `fix_seguranca_rpc_proximo_post_agendado_service_role_only`.
--
-- CAUSA RAIZ, e é o que importa pra não repetir:
--   DROP FUNCTION + CREATE FUNCTION  -> RESETA os grants (default: PUBLIC)
--   CREATE OR REPLACE FUNCTION       -> PRESERVA os grants
-- A função nasceu correta em 09/09 e foi recriada em 10/09 pela migration
-- `rpc_proximo_post_agendado_suporte_imagem_e_carrossel`, perdendo o revoke
-- em silêncio. A irmã dela, rpc_marcar_resultado_publicacao, não foi
-- recriada e por isso manteve o grant certo.
--
-- REGRA: toda migration que recria uma destas três TEM que reemitir o
-- bloco de grants da seção 7. O script de verificação afirma isso.
CREATE OR REPLACE FUNCTION public.rpc_proximo_post_agendado()
 RETURNS TABLE(job_id uuid, post_id uuid, ig_user_id text, token text, video_url text, caption text, media_type text, assets jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'posta_ai', 'vault', 'public'
AS $function$
declare
  v_post_id uuid;
  v_brand_id uuid;
  v_formato text;
  v_ig_user_id text;
  v_token_secret_id uuid;
  v_token text;
  v_assets jsonb;
  v_qtd int;
  v_primeira_url text;
  v_tipo_primeiro text;
  v_corpo text;
  v_assinatura text;
  v_legenda text;
  v_media_type text;
  v_job_id uuid;
  v_erro text;
begin
  with candidato as (
    select p.id
    from posta_ai.posts p
    where p.status = 'agendado'
      and p.agendado_para <= now()
    order by p.agendado_para asc
    limit 1
    for update skip locked
  )
  update posta_ai.posts p
  set status = 'publicando', atualizado_em = now()
  from candidato c
  where p.id = c.id
  returning p.id, p.brand_id, p.formato
  into v_post_id, v_brand_id, v_formato;

  if v_post_id is null then
    return;
  end if;

  select sa.ig_user_id, sa.token_secret_id
  into v_ig_user_id, v_token_secret_id
  from posta_ai.social_accounts sa
  where sa.brand_id = v_brand_id
  limit 1;

  if v_ig_user_id is null then
    update posta_ai.posts set status = 'falhou', atualizado_em = now() where id = v_post_id;
    insert into posta_ai.publish_jobs (post_id, tentativa, status, erro)
    values (v_post_id, 1, 'falhou', 'social_accounts nao encontrado para essa marca');
    return;
  end if;

  select decrypted_secret into v_token
  from vault.decrypted_secrets
  where id = v_token_secret_id;

  select coalesce(
           jsonb_agg(
             jsonb_build_object('ordem', pa.ordem, 'tipo', pa.tipo, 'url', pa.url)
             order by pa.ordem asc
           ),
           '[]'::jsonb
         )
  into v_assets
  from posta_ai.post_assets pa
  where pa.post_id = v_post_id;

  v_qtd := jsonb_array_length(v_assets);

  -- story nunca é carrossel: usa só o primeiro asset
  if v_formato = 'story' and v_qtd > 1 then
    v_assets := jsonb_build_array(v_assets -> 0);
    v_qtd := 1;
  end if;

  if v_qtd = 0 then
    v_erro := 'post sem asset anexado';
  elsif v_qtd > 10 then
    v_erro := format('carrossel aceita no maximo 10 itens (esse post tem %s)', v_qtd);
  end if;

  if v_erro is not null then
    update posta_ai.posts set status = 'falhou', atualizado_em = now() where id = v_post_id;
    insert into posta_ai.publish_jobs (post_id, tentativa, status, erro)
    values (v_post_id, 1, 'falhou', v_erro);
    return;
  end if;

  v_primeira_url  := v_assets -> 0 ->> 'url';
  v_tipo_primeiro := v_assets -> 0 ->> 'tipo';

  select pc.corpo into v_corpo
  from posta_ai.post_captions pc
  where pc.post_id = v_post_id
  order by pc.versao desc
  limit 1;

  select cb.conteudo into v_assinatura
  from posta_ai.caption_blocks cb
  where cb.brand_id = v_brand_id
    and cb.tipo = 'assinatura_padrao'
    and cb.ativo = true
  limit 1;

  v_legenda := coalesce(v_corpo, '');
  if v_assinatura is not null then
    v_legenda := v_legenda || E'\n\n' || v_assinatura;
  end if;

  if v_formato = 'story' then
    v_media_type := 'STORIES';
  elsif v_qtd > 1 then
    v_media_type := 'CAROUSEL';
  elsif v_tipo_primeiro = 'imagem' then
    v_media_type := 'IMAGE';
  else
    v_media_type := 'REELS';
  end if;

  insert into posta_ai.publish_jobs (post_id, tentativa, status)
  values (v_post_id, 1, 'em_andamento')
  returning id into v_job_id;

  return query select v_job_id, v_post_id, v_ig_user_id, v_token,
                      v_primeira_url, v_legenda, v_media_type, v_assets;
end;
$function$
;

-- Grava o resultado da publicação E gera o story COMPANHEIRO (D+1) de todo
-- reel/feed que publicou. Note que usa post_origem_id — coluna diferente da
-- que o rodízio diário usa (story_rodizio_de). As duas automações são
-- independentes de propósito.
CREATE OR REPLACE FUNCTION public.rpc_marcar_resultado_publicacao(p_job_id uuid, p_post_id uuid, p_sucesso boolean, p_ig_creation_id text DEFAULT NULL::text, p_ig_media_id text DEFAULT NULL::text, p_erro text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'posta_ai', 'public'
AS $function$
declare
  v_brand_id uuid;
  v_formato text;
  v_agendado_para timestamptz;
  v_titulo text;
  v_story_id uuid;
  v_asset record;
  v_caption record;
begin
  if p_sucesso then
    update posta_ai.publish_jobs
    set status = 'publicado',
        ig_creation_id = p_ig_creation_id,
        ig_media_id = p_ig_media_id,
        publicado_em = now()
    where id = p_job_id;

    update posta_ai.posts
    set status = 'publicado', atualizado_em = now()
    where id = p_post_id;

    -- gera story companheiro automaticamente, so pra posts de feed/reel,
    -- so uma vez (evita duplicar em caso de retry), e nunca a partir de
    -- um post que ja e ele mesmo um story auto-gerado
    select brand_id, formato, agendado_para, titulo_interno
    into v_brand_id, v_formato, v_agendado_para, v_titulo
    from posta_ai.posts
    where id = p_post_id;

    if v_formato in ('reel', 'feed') and not exists (
      select 1 from posta_ai.posts where post_origem_id = p_post_id
    ) then
      insert into posta_ai.posts (brand_id, titulo_interno, formato, status, agendado_para, post_origem_id)
      values (
        v_brand_id,
        v_titulo || ' — Story (auto)',
        'story',
        'agendado',
        v_agendado_para + interval '1 day',
        p_post_id
      )
      returning id into v_story_id;

      select ordem, tipo, url, duracao_seg into v_asset
      from posta_ai.post_assets
      where post_id = p_post_id
      order by ordem asc
      limit 1;

      insert into posta_ai.post_assets (post_id, ordem, tipo, url, duracao_seg)
      values (v_story_id, 0, v_asset.tipo, v_asset.url, v_asset.duracao_seg);

      select corpo into v_caption
      from posta_ai.post_captions
      where post_id = p_post_id
      order by versao desc
      limit 1;

      if v_caption.corpo is not null then
        insert into posta_ai.post_captions (post_id, versao, corpo, autor)
        values (v_story_id, 1, v_caption.corpo, 'auto');
      end if;
    end if;
  else
    update posta_ai.publish_jobs
    set status = 'falhou', erro = p_erro
    where id = p_job_id;

    update posta_ai.posts
    set status = 'falhou', atualizado_em = now()
    where id = p_post_id;
  end if;
end;
$function$
;

-- Confere o header x-upload-secret da Edge Function emitir-url-upload.
-- O Vault guarda só o SHA-256; o chamador manda o HASH, não o segredo cru,
-- e a comparação acontece aqui dentro — o hash nunca sai do banco.
-- Encoding: HEX minúsculo (daí o lower(trim(...))).
-- Nome do segredo no Vault: 'aprovi_upload_secret_sha256' (com sufixo).
-- O `coalesce` é obrigatório pelo mesmo motivo do posta_ai_is_admin:
-- comparação com NULL devolve NULL, não false.
CREATE OR REPLACE FUNCTION public.rpc_validar_upload(p_hash text, p_brand_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'posta_ai'
AS $function$
declare
  v_esperado text;
begin
  select decrypted_secret into v_esperado
  from vault.decrypted_secrets
  where name = 'aprovi_upload_secret_sha256';

  -- coalesce obrigatorio: comparacao com NULL nao e false, e NULL
  if v_esperado is null
     or lower(trim(v_esperado)) <> lower(trim(coalesce(p_hash, ''))) then
    return 'nao_autorizado';
  end if;

  if not exists (select 1 from posta_ai.brands where id = p_brand_id) then
    return 'marca_inexistente';
  end if;

  return 'ok';
end;
$function$
;


-- =====================================================================
-- 7. GRANTS / REVOKES — extraído de pg_proc.proacl
-- =====================================================================
-- Reemitir este bloco INTEIRO depois de qualquer DROP+CREATE de função.
-- Ver o incidente de 01/10/2026 documentado na seção 6.5.
-- =====================================================================

-- GERADO POR INTROSPEÇÃO de pg_proc.proacl via aclexplode(), não escrito à
-- mão. O padrão é `revoke all` seguido dos grants exatos, porque
-- CREATE FUNCTION concede EXECUTE a PUBLIC por default — e em duas funções
-- produção REVOGA esse default (delete_brand e list_brand_asset_urls). Sem
-- o revoke explícito a réplica nasceria mais permissiva que produção.
--
-- Por que tanta função admin é executável por PUBLIC/anon: a autorização
-- não está no grant, está DENTRO da função (posta_ai_is_admin() levanta
-- 'forbidden', ou entra no WHERE e devolve zero linha). O front usa a anon
-- key, que é pública por design. As 3 RPCs de alto privilégio são a
-- exceção — nelas o grant É a defesa, porque não têm checagem interna.

revoke all on function public.posta_ai_admin_add_comment(p_post_id uuid, p_texto text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_add_comment(p_post_id uuid, p_texto text) to public;
grant execute on function public.posta_ai_admin_add_comment(p_post_id uuid, p_texto text) to anon;
grant execute on function public.posta_ai_admin_add_comment(p_post_id uuid, p_texto text) to authenticated;
grant execute on function public.posta_ai_admin_add_comment(p_post_id uuid, p_texto text) to service_role;
revoke all on function public.posta_ai_admin_create_brand(p_workspace_nome text, p_nome text, p_handle text, p_timezone text, p_idioma text, p_assinatura text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_create_brand(p_workspace_nome text, p_nome text, p_handle text, p_timezone text, p_idioma text, p_assinatura text) to public;
grant execute on function public.posta_ai_admin_create_brand(p_workspace_nome text, p_nome text, p_handle text, p_timezone text, p_idioma text, p_assinatura text) to anon;
grant execute on function public.posta_ai_admin_create_brand(p_workspace_nome text, p_nome text, p_handle text, p_timezone text, p_idioma text, p_assinatura text) to authenticated;
grant execute on function public.posta_ai_admin_create_brand(p_workspace_nome text, p_nome text, p_handle text, p_timezone text, p_idioma text, p_assinatura text) to service_role;
revoke all on function public.posta_ai_admin_create_post(p_brand_id uuid, p_titulo text, p_formato text, p_legenda text, p_assets jsonb) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_create_post(p_brand_id uuid, p_titulo text, p_formato text, p_legenda text, p_assets jsonb) to public;
grant execute on function public.posta_ai_admin_create_post(p_brand_id uuid, p_titulo text, p_formato text, p_legenda text, p_assets jsonb) to anon;
grant execute on function public.posta_ai_admin_create_post(p_brand_id uuid, p_titulo text, p_formato text, p_legenda text, p_assets jsonb) to authenticated;
grant execute on function public.posta_ai_admin_create_post(p_brand_id uuid, p_titulo text, p_formato text, p_legenda text, p_assets jsonb) to service_role;
-- ⚠️ PUBLIC revogado de propósito em produção (não recebe `to public`, nem anon)
revoke all on function public.posta_ai_admin_delete_brand(p_brand_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_delete_brand(p_brand_id uuid) to authenticated;
grant execute on function public.posta_ai_admin_delete_brand(p_brand_id uuid) to service_role;
revoke all on function public.posta_ai_admin_delete_post(p_post_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_delete_post(p_post_id uuid) to public;
grant execute on function public.posta_ai_admin_delete_post(p_post_id uuid) to authenticated;
grant execute on function public.posta_ai_admin_delete_post(p_post_id uuid) to service_role;
revoke all on function public.posta_ai_admin_get_caption_block(p_brand_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_get_caption_block(p_brand_id uuid) to public;
grant execute on function public.posta_ai_admin_get_caption_block(p_brand_id uuid) to anon;
grant execute on function public.posta_ai_admin_get_caption_block(p_brand_id uuid) to authenticated;
grant execute on function public.posta_ai_admin_get_caption_block(p_brand_id uuid) to service_role;
-- ⚠️ PUBLIC revogado de propósito em produção (não recebe `to public`, nem anon)
revoke all on function public.posta_ai_admin_list_brand_asset_urls(p_brand_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_list_brand_asset_urls(p_brand_id uuid) to authenticated;
grant execute on function public.posta_ai_admin_list_brand_asset_urls(p_brand_id uuid) to service_role;
revoke all on function public.posta_ai_admin_list_brands() from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_list_brands() to public;
grant execute on function public.posta_ai_admin_list_brands() to anon;
grant execute on function public.posta_ai_admin_list_brands() to authenticated;
grant execute on function public.posta_ai_admin_list_brands() to service_role;
revoke all on function public.posta_ai_admin_list_posts(p_brand_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_list_posts(p_brand_id uuid) to public;
grant execute on function public.posta_ai_admin_list_posts(p_brand_id uuid) to anon;
grant execute on function public.posta_ai_admin_list_posts(p_brand_id uuid) to authenticated;
grant execute on function public.posta_ai_admin_list_posts(p_brand_id uuid) to service_role;
revoke all on function public.posta_ai_admin_send_for_approval(p_post_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_send_for_approval(p_post_id uuid) to public;
grant execute on function public.posta_ai_admin_send_for_approval(p_post_id uuid) to anon;
grant execute on function public.posta_ai_admin_send_for_approval(p_post_id uuid) to authenticated;
grant execute on function public.posta_ai_admin_send_for_approval(p_post_id uuid) to service_role;
revoke all on function public.posta_ai_admin_set_caption_block(p_brand_id uuid, p_conteudo text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_set_caption_block(p_brand_id uuid, p_conteudo text) to public;
grant execute on function public.posta_ai_admin_set_caption_block(p_brand_id uuid, p_conteudo text) to anon;
grant execute on function public.posta_ai_admin_set_caption_block(p_brand_id uuid, p_conteudo text) to authenticated;
grant execute on function public.posta_ai_admin_set_caption_block(p_brand_id uuid, p_conteudo text) to service_role;
revoke all on function public.posta_ai_admin_set_schedule(p_post_id uuid, p_agendado_para timestamp with time zone) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_set_schedule(p_post_id uuid, p_agendado_para timestamp with time zone) to public;
grant execute on function public.posta_ai_admin_set_schedule(p_post_id uuid, p_agendado_para timestamp with time zone) to anon;
grant execute on function public.posta_ai_admin_set_schedule(p_post_id uuid, p_agendado_para timestamp with time zone) to authenticated;
grant execute on function public.posta_ai_admin_set_schedule(p_post_id uuid, p_agendado_para timestamp with time zone) to service_role;
revoke all on function public.posta_ai_admin_update_caption(p_post_id uuid, p_corpo text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_update_caption(p_post_id uuid, p_corpo text) to public;
grant execute on function public.posta_ai_admin_update_caption(p_post_id uuid, p_corpo text) to authenticated;
grant execute on function public.posta_ai_admin_update_caption(p_post_id uuid, p_corpo text) to service_role;
-- Primitiva interna: PUBLIC tem execute (herdado do default e mantido), mas
-- anon/authenticated não recebem grant nominal. Força bruta no token é
-- inviável — 24 bytes aleatórios = 192 bits.
revoke all on function public.posta_ai_brand_from_token(p_token text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_brand_from_token(p_token text) to public;
grant execute on function public.posta_ai_brand_from_token(p_token text) to service_role;
revoke all on function public.posta_ai_client_decide(p_token text, p_post_id uuid, p_decisao text, p_comentario text, p_legenda text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_client_decide(p_token text, p_post_id uuid, p_decisao text, p_comentario text, p_legenda text) to public;
grant execute on function public.posta_ai_client_decide(p_token text, p_post_id uuid, p_decisao text, p_comentario text, p_legenda text) to anon;
grant execute on function public.posta_ai_client_decide(p_token text, p_post_id uuid, p_decisao text, p_comentario text, p_legenda text) to authenticated;
grant execute on function public.posta_ai_client_decide(p_token text, p_post_id uuid, p_decisao text, p_comentario text, p_legenda text) to service_role;
revoke all on function public.posta_ai_client_feed(p_token text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_client_feed(p_token text) to public;
grant execute on function public.posta_ai_client_feed(p_token text) to anon;
grant execute on function public.posta_ai_client_feed(p_token text) to authenticated;
grant execute on function public.posta_ai_client_feed(p_token text) to service_role;
revoke all on function public.posta_ai_client_update_signature(p_token text, p_conteudo text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_client_update_signature(p_token text, p_conteudo text) to public;
grant execute on function public.posta_ai_client_update_signature(p_token text, p_conteudo text) to anon;
grant execute on function public.posta_ai_client_update_signature(p_token text, p_conteudo text) to authenticated;
grant execute on function public.posta_ai_client_update_signature(p_token text, p_conteudo text) to service_role;
revoke all on function public.posta_ai_is_admin() from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_is_admin() to public;
grant execute on function public.posta_ai_is_admin() to authenticated;
grant execute on function public.posta_ai_is_admin() to service_role;

-- 🔴 AS 3 RPCs DE ALTO PRIVILÉGIO — SÓ service_role. Aqui o grant É a defesa.
revoke all on function public.rpc_marcar_resultado_publicacao(p_job_id uuid, p_post_id uuid, p_sucesso boolean, p_ig_creation_id text, p_ig_media_id text, p_erro text) from public, anon, authenticated, service_role;
grant execute on function public.rpc_marcar_resultado_publicacao(p_job_id uuid, p_post_id uuid, p_sucesso boolean, p_ig_creation_id text, p_ig_media_id text, p_erro text) to service_role;
revoke all on function public.rpc_proximo_post_agendado() from public, anon, authenticated, service_role;
grant execute on function public.rpc_proximo_post_agendado() to service_role;
revoke all on function public.rpc_validar_upload(p_hash text, p_brand_id uuid) from public, anon, authenticated, service_role;
grant execute on function public.rpc_validar_upload(p_hash text, p_brand_id uuid) to service_role;

-- enfileirar_story_diario vive dentro de posta_ai, schema sem USAGE pra
-- anon/authenticated — logo inalcançável por API. Chamada só pelo pg_cron.


-- =====================================================================
-- DÉBITO CONHECIDO — reproduzido de propósito, não corrigido aqui
-- =====================================================================
--
-- 1. ✅ RESOLVIDO em 01/10/2026 — exclusão de post.
--    As três FKs sem ON DELETE (`publish_jobs_post_id_fkey`,
--    `posts_post_origem_id_fkey`, `posts_story_rodizio_de_fkey`) CONTINUAM
--    sem cláusula, de propósito: o histórico de publicação (publish_jobs,
--    com os ig_media_id) e os stories derivados não devem cair em cascata.
--    O conserto foi na função: posta_ai_admin_delete_post agora desvincula
--    os derivados e apaga publish_jobs antes do post, espelhando o padrão
--    que posta_ai_admin_delete_brand já usava. Ver a nota na própria função.
--
-- 2. BUCKET SEM LIMITE EM PRODUÇÃO.
--    `posta-ai-media` tem file_size_limit e allowed_mime_types os dois NULL.
--    A migration 00000000000001 cria o bucket JÁ ENDURECIDO (50 MB + as 6
--    mime types que emitir-url-upload valida) — ou seja, instância nova
--    nasce certa. Produção segue NULL; consertar lá é 1 statement e decisão
--    separada.
--
-- =====================================================================
