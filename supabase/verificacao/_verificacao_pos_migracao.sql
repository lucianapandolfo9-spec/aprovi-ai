-- =====================================================================
-- aprovi.ai — VERIFICAÇÃO PÓS-MIGRAÇÃO
-- =====================================================================
--
-- Rode isto depois de `supabase db push` numa instância nova.
-- Funciona em qualquer cliente (psql, SQL Editor, MCP) — é uma query só,
-- sem meta-comandos do psql.
--
-- LEIA A COLUNA `veredito`. Qualquer linha FALHOU é bloqueador.
--
-- Os blocos:
--   A. ESTRUTURA — o schema foi criado completo?
--   B. SEGURANÇA — as travas estão no lugar?
--   C. INOFENSIVIDADE — esta instância é incapaz de publicar? (só réplica)
--   D. SEMENTE — a semente cobre o que devia?
--
-- O bloco C é o que importa numa réplica. Numa instância de PRODUÇÃO ele
-- vai FALHAR de propósito — produção TEM cron e TEM social_accounts. Veja
-- a nota no fim.
-- =====================================================================

with
-- ---------- A. ESTRUTURA ----------
a as (
  select * from (values
    ('A1', 'tabelas em posta_ai',
      (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='posta_ai' and c.relkind='r')::text, '10'),
    ('A2', 'funcoes do aprovi em public (18 posta_ai_* + 3 rpc_*)',
      (select count(*) from pg_proc
       where pronamespace='public'::regnamespace
         and (proname like 'posta_ai%' or proname in
             ('rpc_proximo_post_agendado','rpc_marcar_resultado_publicacao','rpc_validar_upload')))::text, '21'),
    ('A3', 'funcoes dentro do schema posta_ai',
      (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='posta_ai')::text, '1'),
    ('A4', 'as 3 RPCs sem prefixo posta_ai_ existem (a armadilha)',
      (select count(*) from pg_proc where pronamespace='public'::regnamespace
       and proname in ('rpc_proximo_post_agendado','rpc_marcar_resultado_publicacao','rpc_validar_upload'))::text, '3'),
    ('A5', 'indice parcial idx_posts_agendado_para',
      (select count(*) from pg_indexes where schemaname='posta_ai' and indexname='idx_posts_agendado_para')::text, '1'),
    ('A6', 'bucket posta-ai-media existe',
      (select count(*) from storage.buckets where id='posta-ai-media')::text, '1'),
    ('A7', 'policies de storage do bucket posta-ai-media',
      (select count(*) from pg_policies where schemaname='storage' and tablename='objects'
       and coalesce(qual,'')||coalesce(with_check,'') like '%posta-ai-media%')::text, '4')
  ) as t(id, checagem, obtido, esperado)
),
-- ---------- B. SEGURANÇA ----------
b as (
  select * from (values
    ('B1', 'RLS ligado nas 10 tabelas',
      (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='posta_ai' and c.relkind='r' and c.relrowsecurity)::text, '10'),
    -- Zero policy é o DESENHO, não lacuna: RLS ligado sem policy nega tudo.
    -- Se este virar != 0, alguem "consertou" algo que nao estava quebrado.
    ('B2', 'policies em posta_ai (ZERO e o correto — nega tudo)',
      (select count(*) from pg_policies where schemaname='posta_ai')::text, '0'),
    -- Schema inalcancavel por API.
    ('B3', 'anon NAO tem USAGE no schema posta_ai',
      (select has_schema_privilege('anon','posta_ai','usage'))::text, 'false'),
    ('B4', 'authenticated NAO tem USAGE no schema posta_ai',
      (select has_schema_privilege('authenticated','posta_ai','usage'))::text, 'false'),
    -- 🔴 O INCIDENTE DE 01/10/2026. rpc_proximo_post_agendado decripta o
    -- token da Meta e NAO tem checagem interna — o grant E a defesa.
    -- Esteve aberta a anon porque DROP+CREATE FUNCTION reseta grants.
    ('B5', 'anon NAO executa rpc_proximo_post_agendado (vazava token da Meta)',
      (select has_function_privilege('anon','public.rpc_proximo_post_agendado()','execute'))::text, 'false'),
    ('B6', 'authenticated NAO executa rpc_proximo_post_agendado',
      (select has_function_privilege('authenticated','public.rpc_proximo_post_agendado()','execute'))::text, 'false'),
    ('B7', 'service_role EXECUTA rpc_proximo_post_agendado (senao nada publica)',
      (select has_function_privilege('service_role','public.rpc_proximo_post_agendado()','execute'))::text, 'true'),
    ('B8', 'anon NAO executa rpc_validar_upload',
      (select has_function_privilege('anon','public.rpc_validar_upload(text,uuid)','execute'))::text, 'false'),
    ('B9', 'anon NAO executa rpc_marcar_resultado_publicacao',
      (select has_function_privilege('anon',
        'public.rpc_marcar_resultado_publicacao(uuid,uuid,boolean,text,text,text)','execute'))::text, 'false'),
    -- O coalesce que corrigiu a vulnerabilidade de 29/jul/2026: sem ele,
    -- auth.email() NULL fazia `if not NULL` nao entrar no bloco e TODA
    -- funcao admin passava sem login.
    ('B10', 'posta_ai_is_admin tem o coalesce (bug do auth.email NULL)',
      (select (prosrc ilike '%coalesce%')::text from pg_proc
       where pronamespace='public'::regnamespace and proname='posta_ai_is_admin'), 'true'),
    ('B11', 'rpc_validar_upload tem o coalesce',
      (select (prosrc ilike '%coalesce(p_hash%')::text from pg_proc
       where pronamespace='public'::regnamespace and proname='rpc_validar_upload'), 'true'),
    -- Bucket endurecido: instancia nova nasce com limite, producao (ainda) nao.
    ('B12', 'bucket com file_size_limit definido (producao ainda e NULL)',
      (select (file_size_limit is not null)::text from storage.buckets where id='posta-ai-media'), 'true'),
    ('B13', 'bucket com allowed_mime_types definido',
      (select (allowed_mime_types is not null)::text from storage.buckets where id='posta-ai-media'), 'true')
  ) as t(id, checagem, obtido, esperado)
),
-- ---------- C. INOFENSIVIDADE (réplica) ----------
c as (
  select * from (values
    -- A TRAVA PRINCIPAL. Sem ig_user_id/token_secret_id a RPC marca o post
    -- como 'falhou' e sai — nunca fala com a Meta.
    ('C1', 'social_accounts VAZIA',
      (select count(*) from posta_ai.social_accounts)::text, '0'),
    ('C2', 'ZERO cron job',
      (select count(*) from cron.job)::text, '0'),
    ('C3', 'ZERO objeto no bucket (nenhuma midia de cliente)',
      (select count(*) from storage.objects where bucket_id='posta-ai-media')::text, '0'),
    ('C4', 'NENHUM token da Meta no Vault',
      (select count(*) from vault.secrets where name ilike '%meta%')::text, '0'),
    -- Nenhum post 'agendado' pode vencer dentro de 1 ano. Filtra por status
    -- de propósito: post 'publicado' com data no passado é normal e nao e
    -- pego pela RPC, que so olha status='agendado'.
    ('C5', 'nenhum post agendado vence dentro de 1 ano',
      (select count(*) from posta_ai.posts
       where status='agendado' and agendado_para < now() + interval '1 year')::text, '0'),
    -- A PROVA FINAL: a RPC nao devolve nada. Se devolver linha, alguma das
    -- travas acima nao e a trava que voce pensa que e.
    ('C6', 'rpc_proximo_post_agendado devolve ZERO linha',
      (select count(*) from public.rpc_proximo_post_agendado())::text, '0')
  ) as t(id, checagem, obtido, esperado)
),
-- ---------- D. SEMENTE ----------
d as (
  select * from (values
    ('D1', 'workspaces', (select count(*) from posta_ai.workspaces)::text, '1'),
    -- DUAS marcas: com uma so, o teste de isolamento multi-tenant (token da
    -- marca A tentando ler post da marca B) e impossivel de escrever.
    ('D2', 'brands (2 — isolamento multi-tenant testavel)',
      (select count(*) from posta_ai.brands)::text, '2'),
    ('D3', 'posts', (select count(*) from posta_ai.posts)::text, '14'),
    ('D4', 'todos os 8 status da maquina de estados aparecem',
      (select count(distinct status) from posta_ai.posts)::text, '8'),
    ('D5', 'os 3 valores de post_captions.autor aparecem',
      (select count(distinct autor) from posta_ai.post_captions)::text, '3'),
    ('D6', 'story COMPANHEIRO existe (post_origem_id)',
      (select count(*) from posta_ai.posts where post_origem_id is not null)::text, '1'),
    -- Coluna DIFERENTE de propósito: as duas automacoes de story tem guardas
    -- anti-duplicata independentes. Unificar quebra uma das duas em silencio.
    ('D7', 'story do RODIZIO existe (story_rodizio_de — coluna separada)',
      (select count(*) from posta_ai.posts where story_rodizio_de is not null)::text, '1'),
    ('D8', 'um post com 3 assets (resolve media_type=CAROUSEL)',
      (select count(*) from (select post_id from posta_ai.post_assets
         group by post_id having count(*) = 3) x)::text, '1'),
    ('D9', 'publish_jobs: um publicado e um com erro',
      (select count(distinct status) from posta_ai.publish_jobs)::text, '2'),
    ('D10', 'caption_blocks ativo por marca (senao a legenda sai sem assinatura)',
      (select count(*) from posta_ai.caption_blocks where ativo)::text, '2'),
    -- Token do portal NUNCA literal no repo: 24 bytes em hex = 48 chars.
    ('D11', 'secret_token tem 48 chars (24 bytes aleatorios, nao literal)',
      (select count(*) from posta_ai.brands where length(secret_token) = 48)::text, '2')
  ) as t(id, checagem, obtido, esperado)
),
tudo as (
  select 'A. ESTRUTURA'       as bloco, * from a union all
  select 'B. SEGURANCA'       as bloco, * from b union all
  select 'C. INOFENSIVIDADE'  as bloco, * from c union all
  select 'D. SEMENTE'         as bloco, * from d
)
select bloco, id, checagem, esperado, obtido,
       case when obtido = esperado then 'PASSOU' else '>>> FALHOU <<<' end as veredito
from tudo
order by id;


-- =====================================================================
-- E. PROVA DE ATAQUE — rodar FORA do banco, com curl
-- =====================================================================
-- As checagens acima são feitas de dentro do Postgres. Esta é de fora, com
-- a anon key, que é exatamente o que um atacante tem (ela é pública, está
-- no config.js deste repo).
--
-- A lição registrada no PROJETO.md: testar com curl direto na API, não
-- clicando na tela. Painel pode esconder o que a API expõe.
--
--   REF=<ref-do-projeto>
--   ANON=<anon-key-do-projeto>
--
--   # 1. A RPC que decripta o token da Meta. Esperado: 401 ou 403.
--   #    Se vier 200, PARE — o token da Meta está exposto.
--   curl -s -o /dev/null -w '%{http_code}\n' \
--     -X POST "https://$REF.supabase.co/rest/v1/rpc/rpc_proximo_post_agendado" \
--     -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
--
--   # 2. As tabelas direto. Esperado: 404 (schema não exposto).
--   #    NÃO 200, e NÃO 401 — 401 significaria que o schema está exposto e
--   #    só faltou credencial.
--   curl -s -o /dev/null -w '%{http_code}\n' \
--     "https://$REF.supabase.co/rest/v1/posts?select=id" -H "apikey: $ANON"
--   curl -s -o /dev/null -w '%{http_code}\n' \
--     "https://$REF.supabase.co/rest/v1/social_accounts?select=id" -H "apikey: $ANON"
--
--   # 3. Função admin sem login. Esperado: 200 com corpo VAZIO ou erro
--   #    'forbidden' — nunca lista de marcas. É o teste do bug do
--   #    auth.email() NULL de 29/jul/2026.
--   curl -s -X POST "https://$REF.supabase.co/rest/v1/rpc/posta_ai_admin_list_brands" \
--     -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'Content-Type: application/json' -d '{}'
--
--   # 4. Isolamento multi-tenant: com o token da Marca A, o feed NÃO pode
--   #    conter 'Demo 14 — post da marca B'.
--   TOKEN_A=<secret_token da Marca Demo A>
--   curl -s -X POST "https://$REF.supabase.co/rest/v1/rpc/posta_ai_client_feed" \
--     -H "apikey: $ANON" -H 'Content-Type: application/json' \
--     -d "{\"p_token\":\"$TOKEN_A\"}" | grep -c 'marca B'    # esperado: 0


-- =====================================================================
-- RODANDO ISTO EM PRODUÇÃO
-- =====================================================================
-- O bloco C (INOFENSIVIDADE) vai FALHAR em produção, e isso é correto:
-- produção TEM 2 cron jobs, TEM social_accounts preenchida, TEM 49 objetos
-- no bucket e TEM os tokens da Meta no Vault. Em produção, ignore o bloco C
-- e confira que A, B e E passam.
--
-- O bloco D também falha em produção — lá os dados são reais, não semente.
--
-- Em produção, duas checagens de B valem atenção especial:
--   B12/B13 — o bucket de lá ainda tem os dois limites NULL (pendência nº2
--   do PROJETO.md). É esperado FALHAR até ela decidir endurecer.
-- =====================================================================
