-- =====================================================================
-- aprovi.ai — SEMENTE DE DEMONSTRAÇÃO
-- =====================================================================
--
-- 🔴 NENHUM DADO DE CLIENTE. Nada aqui veio de produção.
--
-- Por que é uma migration numerada 9… e não `supabase/seed.sql`:
-- o `seed.sql` do Supabase CLI só roda em `supabase start` (stack local via
-- Docker) — ele NÃO é aplicado contra um projeto remoto por `db push`. A
-- alternativa seria colar SQL no SQL Editor do painel, o que contraria a
-- regra de operar o Supabase só por API/MCP. Migration com prefixo 9
-- garante que é sempre a última a rodar e dispensa humano.
--
-- Se um dia esta instância deixar de ser demo, apague os dados:
--   select public.posta_ai_admin_delete_brand(id) from posta_ai.brands
--   where id in ('aa000000-0000-4000-8000-000000000001',
--                'bb000000-0000-4000-8000-000000000002');
--   delete from posta_ai.workspaces where id = '00000000-0000-4000-8000-000000000001';
--
-- O QUE A SEMENTE EXERCITA
--   * a máquina de estados completa — todos os 8 status
--   * as DUAS automações de story, nas suas colunas separadas
--     (post_origem_id = companheiro;  story_rodizio_de = rodízio diário)
--   * os 4 media_type que a RPC resolve: REELS, IMAGE, CAROUSEL, STORIES
--   * os 3 valores de post_captions.autor: editor, aprovador, auto
--   * isolamento multi-tenant — DUAS marcas, não uma. Com uma só, o teste
--     que importa (token da marca A tentando ler post da marca B) é
--     impossível de escrever.
--   * superfície de erro não-vazia: um publish_jobs com `erro` preenchido
--
-- O QUE A SEMENTE DELIBERADAMENTE NÃO FAZ
--   * `social_accounts` fica VAZIA — sem ig_user_id e sem token_secret_id,
--     a réplica é fisicamente incapaz de publicar
--   * `secret_token` NUNCA é literal — vem do default da coluna,
--     encode(gen_random_bytes(24),'hex'). É a única credencial do portal do
--     cliente e este repo é público.
--   * todo `agendado_para` de post com status 'agendado' fica a 10 ANOS no
--     futuro. Nada vence por acidente.
--   * `post_assets.url` aponta pra `demo.invalid` — TLD reservada pela
--     RFC 2606, que por definição NUNCA resolve em DNS nenhum. Escolhida de
--     propósito em vez do domínio da réplica: mesmo que alguém pluguasse um
--     token da Meta aqui, a Meta não conseguiria baixar mídia nenhuma.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Workspace e as 2 marcas
-- ---------------------------------------------------------------------
insert into posta_ai.workspaces (id, nome) values
  ('00000000-0000-4000-8000-000000000001', 'Workspace Demo');

-- secret_token OMITIDO de propósito nas duas: o default gera 24 bytes
-- aleatórios em hex. Pra pegar os links do portal depois de aplicar,
-- rode a consulta no fim deste arquivo.
insert into posta_ai.brands (id, workspace_id, nome, handle, timezone, idioma) values
  ('aa000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
   'Marca Demo A', '@demo_a', 'America/Recife', 'pt'),
  -- Timezone diferente de propósito: exercita o cálculo por timezone NOMEADA
  -- do rodízio de story, que é onde o horário de verão morde.
  ('bb000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
   'Marca Demo B', '@demo_b', 'America/Los_Angeles', 'en');

-- Sem caption_blocks ativo, a RPC monta legenda sem assinatura — e o bug
-- passa sem ninguém ver. Uma por marca.
insert into posta_ai.caption_blocks (brand_id, tipo, conteudo, ativo) values
  ('aa000000-0000-4000-8000-000000000001', 'assinatura_padrao',
   E'— Marca Demo A\n#demo #aprovi', true),
  ('bb000000-0000-4000-8000-000000000002', 'assinatura_padrao',
   E'— Demo B\n#demo', true);


-- ---------------------------------------------------------------------
-- Posts — 14, cobrindo a máquina de estados inteira
-- ---------------------------------------------------------------------
insert into posta_ai.posts (id, brand_id, titulo_interno, formato, status, agendado_para, post_origem_id, story_rodizio_de) values
  -- 01 entrada da máquina
  ('11000000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001',
   'Demo 01 — rascunho', 'reel', 'rascunho', null, null, null),
  -- 02 esperando o cliente
  ('11000000-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001',
   'Demo 02 — em aprovacao', 'reel', 'em_aprovacao', null, null, null),
  -- 03 cliente pediu refazer o VÍDEO (não é mudança de legenda — essa não
  --    passa por ajuste_pedido). Tem post_comments obrigatório.
  ('11000000-0000-4000-8000-000000000003', 'aa000000-0000-4000-8000-000000000001',
   'Demo 03 — ajuste pedido', 'reel', 'ajuste_pedido', null, null, null),
  -- 04 cliente editou a legenda E aprovou na mesma ação -> caption v2 com
  --    autor='aprovador'
  ('11000000-0000-4000-8000-000000000004', 'aa000000-0000-4000-8000-000000000001',
   'Demo 04 — aprovado com legenda editada', 'reel', 'aprovado', null, null, null),
  -- 05 agendado. +10 anos: nunca vence por acidente.
  ('11000000-0000-4000-8000-000000000005', 'aa000000-0000-4000-8000-000000000001',
   'Demo 05 — agendado', 'reel', 'agendado', now() + interval '10 years', null, null),
  -- 06 travado em voo: deixa visível o caminho do lock
  --    (for update skip locked) sem precisar provocar corrida.
  ('11000000-0000-4000-8000-000000000006', 'aa000000-0000-4000-8000-000000000001',
   'Demo 06 — publicando', 'reel', 'publicando', now() - interval '2 days', null, null),
  -- 07 publicado. Tem publish_jobs de sucesso e gerou o story companheiro 08.
  ('11000000-0000-4000-8000-000000000007', 'aa000000-0000-4000-8000-000000000001',
   'Demo 07 — publicado', 'reel', 'publicado', now() - interval '3 days', null, null),
  -- 08 STORY COMPANHEIRO: nasce de post_origem_id. Esta é a automação do
  --    rpc_marcar_resultado_publicacao (D+1 depois do feed publicar).
  ('11000000-0000-4000-8000-000000000008', 'aa000000-0000-4000-8000-000000000001',
   'Demo 07 — publicado — Story (auto)', 'story', 'agendado', now() + interval '10 years',
   '11000000-0000-4000-8000-000000000007', null),
  -- 09 falhou. Tem publish_jobs com erro preenchido.
  ('11000000-0000-4000-8000-000000000009', 'aa000000-0000-4000-8000-000000000001',
   'Demo 09 — falhou', 'reel', 'falhou', now() - interval '1 day', null, null),
  -- 10 fonte do rodízio diário
  ('11000000-0000-4000-8000-000000000010', 'aa000000-0000-4000-8000-000000000001',
   'Demo 10 — fonte do rodizio', 'reel', 'aprovado', null, null, null),
  -- 11 STORY DO RODÍZIO: nasce de story_rodizio_de, COLUNA DIFERENTE do 08.
  --    As duas automações têm guardas anti-duplicata independentes — é por
  --    isso que as colunas são separadas. Se alguém unificar, uma das duas
  --    para de funcionar em silêncio.
  ('11000000-0000-4000-8000-000000000011', 'aa000000-0000-4000-8000-000000000001',
   'Demo 10 — fonte do rodizio — Story (rodízio)', 'story', 'agendado', now() + interval '10 years',
   null, '11000000-0000-4000-8000-000000000010'),
  -- 12 três assets misturando imagem e vídeo -> a RPC tem que resolver
  --    media_type = 'CAROUSEL'
  ('11000000-0000-4000-8000-000000000012', 'aa000000-0000-4000-8000-000000000001',
   'Demo 12 — carrossel 3 itens', 'carrossel', 'aprovado', null, null, null),
  -- 13 um asset de imagem -> media_type = 'IMAGE'
  ('11000000-0000-4000-8000-000000000013', 'aa000000-0000-4000-8000-000000000001',
   'Demo 13 — imagem unica', 'feed', 'aprovado', null, null, null),
  -- 14 MARCA B. Existe pra o teste de isolamento: chamar
  --    posta_ai_client_feed com o token da marca A NÃO pode devolver este.
  ('22000000-0000-4000-8000-000000000014', 'bb000000-0000-4000-8000-000000000002',
   'Demo 14 — post da marca B', 'reel', 'em_aprovacao', null, null, null);


-- ---------------------------------------------------------------------
-- Assets — URLs em demo.invalid, que NUNCA resolvem (RFC 2606)
-- ---------------------------------------------------------------------
insert into posta_ai.post_assets (post_id, ordem, tipo, url, duracao_seg) values
  ('11000000-0000-4000-8000-000000000004', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/04-aprovado.mp4', 22.5),
  ('11000000-0000-4000-8000-000000000005', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/05-agendado.mp4', 18.0),
  ('11000000-0000-4000-8000-000000000006', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/06-publicando.mp4', 31.2),
  ('11000000-0000-4000-8000-000000000007', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/07-publicado.mp4', 27.8),
  -- o story companheiro reaproveita o MESMO arquivo do post de origem,
  -- igual ao que rpc_marcar_resultado_publicacao faz
  ('11000000-0000-4000-8000-000000000008', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/07-publicado.mp4', 27.8),
  ('11000000-0000-4000-8000-000000000009', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/09-falhou.mp4', 15.0),
  ('11000000-0000-4000-8000-000000000010', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/10-fonte-rodizio.mp4', 24.0),
  -- idem pro story do rodízio
  ('11000000-0000-4000-8000-000000000011', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-a/10-fonte-rodizio.mp4', 24.0),
  -- CAROUSEL: 3 itens, tipos misturados, ordem explícita
  ('11000000-0000-4000-8000-000000000012', 0, 'imagem', 'https://demo.invalid/posta-ai-media/demo-a/12-carrossel-0.jpg', null),
  ('11000000-0000-4000-8000-000000000012', 1, 'video', 'https://demo.invalid/posta-ai-media/demo-a/12-carrossel-1.mp4', 12.0),
  ('11000000-0000-4000-8000-000000000012', 2, 'imagem', 'https://demo.invalid/posta-ai-media/demo-a/12-carrossel-2.png', null),
  -- IMAGE
  ('11000000-0000-4000-8000-000000000013', 0, 'imagem', 'https://demo.invalid/posta-ai-media/demo-a/13-imagem.jpg', null),
  ('22000000-0000-4000-8000-000000000014', 0, 'video', 'https://demo.invalid/posta-ai-media/demo-b/14-marca-b.mp4', 20.0);


-- ---------------------------------------------------------------------
-- Legendas — cobre os 3 valores de `autor`
-- ---------------------------------------------------------------------
insert into posta_ai.post_captions (post_id, versao, corpo, autor) values
  ('11000000-0000-4000-8000-000000000002', 1, 'Legenda escrita pela editora.', 'editor'),
  ('11000000-0000-4000-8000-000000000003', 1, 'Legenda do post que precisa de novo video.', 'editor'),
  -- v1 da editora, v2 do cliente: prova o fluxo "edita e aprova na mesma ação"
  ('11000000-0000-4000-8000-000000000004', 1, 'Primeira versao, escrita pela editora.', 'editor'),
  ('11000000-0000-4000-8000-000000000004', 2, 'Versao do cliente, editada na hora de aprovar.', 'aprovador'),
  ('11000000-0000-4000-8000-000000000005', 1, 'Legenda do post agendado.', 'editor'),
  ('11000000-0000-4000-8000-000000000007', 1, 'Legenda do post que publicou.', 'editor'),
  -- 'auto' existe exatamente pra isto: legenda copiada por automação.
  -- Sem este valor no check de post_captions.autor, o insert automático
  -- do story companheiro violaria o constraint.
  ('11000000-0000-4000-8000-000000000008', 1, 'Legenda do post que publicou.', 'auto'),
  ('11000000-0000-4000-8000-000000000010', 1, 'Legenda da fonte do rodizio.', 'editor'),
  ('11000000-0000-4000-8000-000000000011', 1, 'Legenda da fonte do rodizio.', 'auto'),
  ('11000000-0000-4000-8000-000000000012', 1, 'Legenda do carrossel de 3 itens.', 'editor'),
  ('11000000-0000-4000-8000-000000000013', 1, 'Legenda da imagem unica.', 'editor'),
  ('22000000-0000-4000-8000-000000000014', 1, 'Legenda do post da marca B.', 'editor');


-- ---------------------------------------------------------------------
-- Comentários — feedback de aprovação, NÃO comentário do Instagram
-- ---------------------------------------------------------------------
insert into posta_ai.post_comments (post_id, autor, texto) values
  ('11000000-0000-4000-8000-000000000003', 'aprovador', 'O corte do inicio ficou seco, pode refazer?'),
  ('11000000-0000-4000-8000-000000000003', 'editor', 'Fechado, refaço e devolvo hoje.');


-- ---------------------------------------------------------------------
-- Eventos de status
-- ---------------------------------------------------------------------
insert into posta_ai.post_events (post_id, de_status, para_status, autor) values
  ('11000000-0000-4000-8000-000000000002', 'rascunho',     'em_aprovacao',  'editor'),
  ('11000000-0000-4000-8000-000000000003', 'em_aprovacao', 'ajuste_pedido', 'aprovador'),
  ('11000000-0000-4000-8000-000000000004', 'em_aprovacao', 'aprovado',      'aprovador'),
  ('11000000-0000-4000-8000-000000000005', 'aprovado',     'agendado',      'editor'),
  ('11000000-0000-4000-8000-000000000007', 'publicando',   'publicado',     'sistema'),
  ('11000000-0000-4000-8000-000000000009', 'publicando',   'falhou',        'sistema');


-- ---------------------------------------------------------------------
-- publish_jobs — um sucesso e um erro, pra a superfície de falha não
-- nascer vazia e ninguém descobrir só na primeira falha real
-- ---------------------------------------------------------------------
insert into posta_ai.publish_jobs (post_id, tentativa, ig_creation_id, ig_media_id, status, erro, publicado_em) values
  ('11000000-0000-4000-8000-000000000007', 1, 'DEMO_CREATION_ID_0007', 'DEMO_MEDIA_ID_0007',
   'publicado', null, now() - interval '3 days'),
  ('11000000-0000-4000-8000-000000000009', 1, null, null,
   'falhou',
   'erro ao criar container: {"error":{"message":"DEMO — falha sintetica da semente, nao aconteceu de verdade","code":9004}}',
   null);


-- ---------------------------------------------------------------------
-- posta_ai.social_accounts — INTENCIONALMENTE VAZIA
-- ---------------------------------------------------------------------
-- É a trava principal. Sem ig_user_id e sem token_secret_id,
-- rpc_proximo_post_agendado marca o post como 'falhou' e sai — nunca
-- chega a falar com a Meta. Não preencha "só pra testar".


-- =====================================================================
-- DEPOIS DE APLICAR — pegue os links do portal do cliente
-- =====================================================================
-- Os tokens foram gerados aleatoriamente pelo banco, então só existem aqui:
--
--   select nome, handle,
--          'https://<SEU_HOST>/cliente.html?t=' || secret_token as link_do_portal
--   from posta_ai.brands order by nome;
--
-- ⚠️ Esses links dão acesso de leitura e aprovação à marca. Trate como
-- senha: não cole em chat, não commite, não mande por e-mail sem necessidade.
-- =====================================================================
