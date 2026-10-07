-- =====================================================================
-- aprovi.ai — CADASTRO DA MARCA "CERTO AGRO" (item 6 do desenho de 06/10/2026)
-- =====================================================================
-- Dado de produção, não schema: por isso mora em supabase/cadastros/ e não
-- em migrations/. NÃO FOI APLICADO. Aplicar só com o ok da Luciana.
--
-- Desenho: Obvision/Luh Panda/Dev/Sistemas/aprovi.ai/
--          "Certo Agro no aprovi.ai — Desenho (grill 06-10-2026).md"
--
-- 🔴 ORDEM EM PRODUÇÃO (projeto tscnqvuzlfagotirgjbz):
--    1) migration 00000000000004_facebook_stories_automacao_limpeza.sql
--    2) deploy da v21 de publicar-posts-agendados
--    3) ESTE arquivo
--    Cadastrar antes da v21 faria o post sair só no Instagram (a v20 ignora
--    o canal facebook). O bloco 0 aborta se a migration 4 ainda não entrou.
--
-- Acesso conferido em 06/10/2026 com o token central do Vault
-- (meta_system_user_token_central_luhpanda, SYSTEM_USER, não expira):
--   Página "Certo Agro"  1358218360707076  tasks MANAGE + CREATE_CONTENT,
--                                          page token emitido
--   Instagram @cert.oagro 17841424564376088 ligado à Página, quota de
--                                          publicação 0/100 em 24h
--
-- Nada secreto neste arquivo:
--   * o token da Meta entra por referência ao Vault (token_secret_id);
--   * o segredo da automação entra só como SHA-256. O valor cru mora em
--     ~/.claude/skills/certo-agro/secrets/aprovi-automacao-cotacao-secret.txt
--     (chmod 600) e vai pra credencial do n8n, nunca pra chat nem banco;
--   * o secret_token da marca (link de aprovação) é gerado pelo default
--     da coluna. Ler depois no banco, nunca escrever literal aqui.
--
-- WORKSPACE — preparado pro "Luh Panda" (0f495bb3-…). Pra a marca ter
-- workspace próprio, trocar o bloco 1 por:
--     insert into posta_ai.workspaces (id, nome)
--     values ('<uuid novo>', 'Certo Agro') on conflict (id) do nothing;
-- e usar esse uuid em brands.workspace_id. Nada mais muda: o admin hoje
-- é por e-mail (posta_ai_is_admin) e a aprovação é pelo link da marca,
-- então o workspace não muda acesso de ninguém (o Túlio não enxerga
-- nada em nenhum dos dois casos).
--
-- Idempotente: rodar duas vezes não duplica nada.
-- =====================================================================

begin;

-- 0. Trava: a migration 4 tem que estar aplicada
do $$
begin
  if to_regclass('posta_ai.story_horarios') is null
     or to_regclass('posta_ai.automacoes') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'posta_ai' and table_name = 'social_accounts'
                      and column_name = 'publicar_facebook') then
    raise exception 'migration 00000000000004 ainda não foi aplicada — parar';
  end if;
  if not exists (select 1 from vault.secrets
                 where id = 'bb2a0eec-7f12-48e4-bcbb-63d8ef308a6a'
                   and name = 'meta_system_user_token_central_luhpanda') then
    raise exception 'token central não encontrado no Vault — parar';
  end if;
end $$;

-- 1. Marca (workspace Luh Panda). id fixo: a pasta do Storage e o n8n
--    dependem dele.
insert into posta_ai.brands (id, workspace_id, nome, handle, timezone, idioma)
values ('f177c68e-a912-42c6-bc0c-48d790d73cfe',
        '0f495bb3-2ca4-4a87-ac64-fdf3d7a0e7e6',   -- workspace "Luh Panda"
        'Certo Agro', 'cert.oagro', 'America/Recife', 'pt')
on conflict (id) do nothing;

-- 2. Conta social: um registro, dois canais (decisão 7 — um post sai nos dois)
insert into posta_ai.social_accounts
  (brand_id, ig_user_id, page_id, ad_account_id, token_secret_id, meta_app_id,
   permissoes, expira_em, publicar_instagram, publicar_facebook)
select 'f177c68e-a912-42c6-bc0c-48d790d73cfe',
       '17841424564376088',                       -- IG @cert.oagro
       '1358218360707076',                        -- Página "Certo Agro"
       'act_1183291261276741',                    -- conta de anúncios Certo Agro (sem pagamento)
       'bb2a0eec-7f12-48e4-bcbb-63d8ef308a6a',    -- Vault: token central
       '2282353462577676',
       array['instagram_basic', 'instagram_content_publish', 'pages_show_list',
             'pages_read_engagement', 'pages_manage_posts', 'pages_manage_ads',
             'ads_management', 'ads_read', 'business_management'],
       null, true, true
where not exists (select 1 from posta_ai.social_accounts
                  where brand_id = 'f177c68e-a912-42c6-bc0c-48d790d73cfe');

-- 3. Horários de story (decisão 8), fuso America/Recife
--    07:00 seg–sex  → story de COTAÇÃO, criado pela automação (bloco 4).
--                     Não entra aqui de propósito: se fosse "repost", o
--                     companheiro do feed podia ocupar as 7h e a cotação
--                     cairia em cima dele.
--    12:00 seg–sex  → repost: o feed das 18h vira story no próximo 12:00 útil
--                     (feed de sexta → story de segunda).
--    09:00 sáb–dom  → rodízio, criado DESLIGADO. Falta: (a) o banco fixo
--                     de fim de semana, ainda não decidido; (b) o rodízio só
--                     sorteia VÍDEO de feed/reel aprovado; (c) marca com
--                     rodízio ativo tem a mídia de feed/reel PROTEGIDA da
--                     limpeza de 30 dias (rpc_midia_expirada) — ligar isto
--                     anula a decisão 10 pro Certo Agro; (d) precisa de um
--                     cron próprio (o jobid 2 é só da Gigi), ex.:
--       select cron.schedule('story-diario-certo-agro', '0 11 * * *',
--         $c$ select posta_ai.enfileirar_story_diario('f177c68e-a912-42c6-bc0c-48d790d73cfe') $c$);
insert into posta_ai.story_horarios (brand_id, tipo, hora, dias_semana, ativo) values
  ('f177c68e-a912-42c6-bc0c-48d790d73cfe', 'repost',  '12:00', '{1,2,3,4,5}', true),
  ('f177c68e-a912-42c6-bc0c-48d790d73cfe', 'rodizio', '09:00', '{6,7}',       false)
on conflict (brand_id, tipo, hora) do nothing;

-- 4. Automação do story de cotação (decisões 5 e 9): molde aprovado 1x,
--    o post nasce `agendado`. Segredo: só o SHA-256.
--    ⚠️ molde_aprovado = FALSE até ela aprovar o visual do card (pendência
--    do desenho). Enquanto false, cada story nasce `em_aprovacao` e passa
--    pelo link da marca. Depois do ok dela:
--      update posta_ai.automacoes
--         set molde_aprovado = true, molde_ref = '<arquivo/commit do molde>'
--       where nome = 'certo-agro-story-cotacao';
insert into posta_ai.automacoes
  (brand_id, nome, descricao, segredo_sha256, formatos, molde_aprovado, molde_ref, url_base_midia)
values
  ('f177c68e-a912-42c6-bc0c-48d790d73cfe',
   'certo-agro-story-cotacao',
   'n8n na VPS: lê cotacao_arroba (Supabase Certo Agro), gera PNG 9:16 pelo molde O2 versão story, sobe no Storage e cria o story das 7h seg–sex. Travas: 4 praças mesma data, máx. 3 dias úteis pelo criado_em, sem fim de semana/feriado.',
   '92f3317b01c743f272ed022828e3ab2581d370ab80ba11e3a0ad9437756b4f61',
   '{story}',
   false,
   null,
   'https://tscnqvuzlfagotirgjbz.supabase.co/storage/v1/object/public/posta-ai-media/f177c68e-a912-42c6-bc0c-48d790d73cfe/')
on conflict (nome) do nothing;

-- 5. Conferência (sai no resultado; não mostra secret_token)
select b.nome, b.handle, b.timezone, w.nome as workspace,
       sa.ig_user_id, sa.page_id, sa.publicar_instagram, sa.publicar_facebook,
       (select count(*) from posta_ai.story_horarios h where h.brand_id = b.id and h.ativo) as horarios_ativos,
       (select molde_aprovado from posta_ai.automacoes a where a.brand_id = b.id) as molde_aprovado
from posta_ai.brands b
join posta_ai.workspaces w on w.id = b.workspace_id
left join posta_ai.social_accounts sa on sa.brand_id = b.id
where b.id = 'f177c68e-a912-42c6-bc0c-48d790d73cfe';

commit;

-- Link de aprovação (Luciana ou Thiago), depois de aplicar — ler, não colar em chat:
--   select 'https://luhpanda.online/cliente.html?t=' || secret_token
--   from posta_ai.brands where id = 'f177c68e-a912-42c6-bc0c-48d790d73cfe';
