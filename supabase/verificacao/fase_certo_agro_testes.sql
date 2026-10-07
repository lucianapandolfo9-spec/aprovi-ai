-- =====================================================================
-- aprovi.ai — TESTES da fase "Certo Agro no aprovi.ai" (06/10/2026)
-- =====================================================================
-- Roda SÓ em banco local/réplica (supabase start). Tudo dentro de uma
-- transação com ROLLBACK no fim: nada fica gravado.
--   docker exec -i supabase_db_aprovi-ai psql -U postgres -v ON_ERROR_STOP=1 \
--     < supabase/verificacao/fase_certo_agro_testes.sql
-- Cada bloco termina com RAISE NOTICE 'OK Tn ...'. Falha = exceção, para tudo.
--
-- O oráculo do rodízio é a definição de PRODUÇÃO de enfileirar_story_diario
-- de antes desta fase (baixada por pg_get_functiondef em 06/10/2026),
-- recriada abaixo em pg_temp. O teste T2 roda a antiga e a nova no MESMO
-- estado e no MESMO now() e exige resultado idêntico.
-- =====================================================================
begin;

CREATE OR REPLACE FUNCTION pg_temp.old_enfileirar(p_brand_id uuid)
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

-- ---------- fixtures ----------
insert into posta_ai.workspaces (id, nome) values ('11111111-0000-4000-8000-000000000000', 'teste');
select vault.create_secret('token-falso-de-teste', 'teste_token_meta', 'teste') as sid \gset
-- G = Gigi de mentira (LA, rodízio 12:00, só IG) · C = Certo Agro de mentira (Recife, IG+FB, repost 12:00 seg-sex)
-- L = Luh Panda de mentira (Recife, só IG, sem horário nenhum)
insert into posta_ai.brands (id, workspace_id, nome, timezone) values
  ('aaaaaaaa-0000-4000-8000-00000000000a', '11111111-0000-4000-8000-000000000000', 'G', 'America/Los_Angeles'),
  ('cccccccc-0000-4000-8000-00000000000c', '11111111-0000-4000-8000-000000000000', 'C', 'America/Recife'),
  ('dddddddd-0000-4000-8000-00000000000d', '11111111-0000-4000-8000-000000000000', 'L', 'America/Recife');
insert into posta_ai.story_horarios (brand_id, tipo, hora, dias_semana) values
  ('aaaaaaaa-0000-4000-8000-00000000000a', 'rodizio', '12:00', '{1,2,3,4,5,6,7}'),
  ('cccccccc-0000-4000-8000-00000000000c', 'repost',  '12:00', '{1,2,3,4,5}');
insert into posta_ai.social_accounts (brand_id, ig_user_id, page_id, token_secret_id, publicar_instagram, publicar_facebook) values
  ('aaaaaaaa-0000-4000-8000-00000000000a', 'IG_G', 'PG_G', :'sid', true, false),
  ('cccccccc-0000-4000-8000-00000000000c', 'IG_C', 'PG_C', :'sid', true, true),
  ('dddddddd-0000-4000-8000-00000000000d', 'IG_L', 'PG_L', :'sid', true, false);
insert into posta_ai.caption_blocks (brand_id, conteudo) values ('cccccccc-0000-4000-8000-00000000000c', '#certoagro');

-- 3 reels aprovados da G (fonte do rodízio)
insert into posta_ai.posts (id, brand_id, titulo_interno, formato, status, criado_em) values
  ('a0000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-00000000000a', 'R1', 'reel', 'publicado', now() - interval '9 days'),
  ('a0000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-00000000000a', 'R2', 'reel', 'aprovado',  now() - interval '8 days'),
  ('a0000000-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-00000000000a', 'R3', 'reel', 'agendado',  now() - interval '7 days');
update posta_ai.posts set agendado_para = now() + interval '30 days' where id = 'a0000000-0000-4000-8000-000000000003';
insert into posta_ai.post_assets (post_id, ordem, tipo, url) values
  ('a0000000-0000-4000-8000-000000000001', 0, 'video', 'https://x.supabase.co/storage/v1/object/public/posta-ai-media/g/r1.mp4'),
  ('a0000000-0000-4000-8000-000000000002', 0, 'video', 'https://x.supabase.co/storage/v1/object/public/posta-ai-media/g/r2.mp4'),
  ('a0000000-0000-4000-8000-000000000003', 0, 'video', 'https://x.supabase.co/storage/v1/object/public/posta-ai-media/g/r3.mp4');
insert into posta_ai.post_captions (post_id, corpo) values ('a0000000-0000-4000-8000-000000000001', 'legenda r1');

-- ---------- T1: grants ----------
do $$
declare r record;
begin
  for r in select * from (values
      ('public.rpc_proximo_job_publicacao()'),
      ('public.rpc_marcar_resultado_job(uuid,boolean,text,text,text,text,text)'),
      ('public.rpc_midia_expirada(integer)'),
      ('public.rpc_marcar_midia_removida(text[])'),
      ('posta_ai.proximo_horario_livre(uuid,text,timestamptz,integer)'),
      ('posta_ai.gerar_story_companheiro(uuid)'),
      ('posta_ai.finalizar_publicacao(uuid,uuid)'),
      ('posta_ai.enfileirar_story_diario(uuid)'),
      ('posta_ai.ceifar_jobs_orfaos()')) v(f)
  loop
    assert not has_function_privilege('anon', r.f, 'execute'), 'anon executa ' || r.f;
    assert not has_function_privilege('authenticated', r.f, 'execute'), 'authenticated executa ' || r.f;
  end loop;
  assert has_function_privilege('service_role', 'public.rpc_proximo_job_publicacao()', 'execute');
  assert has_function_privilege('service_role', 'public.rpc_marcar_resultado_job(uuid,boolean,text,text,text,text,text)', 'execute');
  assert has_function_privilege('service_role', 'posta_ai.enfileirar_story_diario(uuid)', 'execute');
  assert has_function_privilege('anon', 'public.posta_ai_automacao_criar_post(text,text,text,text,timestamptz,jsonb,text,text)', 'execute');
  -- funções antigas intactas
  assert not has_function_privilege('anon', 'public.rpc_proximo_post_agendado()', 'execute');
  -- RLS ligado e zero policy nas tabelas novas
  assert (select bool_and(relrowsecurity) from pg_class where oid in ('posta_ai.story_horarios'::regclass, 'posta_ai.automacoes'::regclass));
  assert (select count(*) from pg_policies where schemaname = 'posta_ai') = 0, 'apareceu policy em posta_ai';
  raise notice 'OK T1 grants e RLS';
end $$;

-- ---------- T2: rodízio novo == rodízio antigo (mesmo estado, mesmo now) ----------
do $$
declare
  v_old uuid; v_new uuid; o record; n record;
begin
  -- cenário A: dia vazio
  v_old := pg_temp.old_enfileirar('aaaaaaaa-0000-4000-8000-00000000000a');
  select agendado_para, story_rodizio_de, titulo_interno into o from posta_ai.posts where id = v_old;
  delete from posta_ai.post_captions where post_id = v_old;
  delete from posta_ai.post_assets where post_id = v_old;
  delete from posta_ai.posts where id = v_old;
  v_new := posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a');
  select agendado_para, story_rodizio_de, titulo_interno into n from posta_ai.posts where id = v_new;
  assert v_old is not null and v_new is not null, 'A: um dos dois não criou';
  assert o.agendado_para = n.agendado_para, format('A: horário diferente %s x %s', o.agendado_para, n.agendado_para);
  assert o.story_rodizio_de = n.story_rodizio_de, 'A: fonte diferente';
  assert o.titulo_interno = n.titulo_interno, 'A: título diferente';
  assert (n.agendado_para at time zone 'America/Los_Angeles')::time = '12:00', 'A: não é meio-dia LA';
  -- cenário B: chamado de novo (dia já tem o story) → os dois devolvem NULL
  assert pg_temp.old_enfileirar('aaaaaaaa-0000-4000-8000-00000000000a') is null, 'B: antiga criou de novo';
  assert posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a') is null, 'B: nova criou de novo';
  -- cenário C: o dia tem um story companheiro em OUTRO horário → os dois cedem
  update posta_ai.posts set agendado_para = agendado_para - interval '1 hour', story_rodizio_de = null,
         post_origem_id = 'a0000000-0000-4000-8000-000000000001' where id = v_new;
  assert pg_temp.old_enfileirar('aaaaaaaa-0000-4000-8000-00000000000a') is null, 'C: antiga não cedeu';
  assert posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a') is null, 'C: nova não cedeu';
  -- cenário D: o story existente falhou → os dois criam de novo, mesma fonte
  update posta_ai.posts set status = 'falhou' where id = v_new;
  v_old := pg_temp.old_enfileirar('aaaaaaaa-0000-4000-8000-00000000000a');
  select agendado_para, story_rodizio_de into o from posta_ai.posts where id = v_old;
  delete from posta_ai.post_captions where post_id = v_old; delete from posta_ai.post_assets where post_id = v_old; delete from posta_ai.posts where id = v_old;
  v_new := posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a');
  select agendado_para, story_rodizio_de into n from posta_ai.posts where id = v_new;
  assert o.agendado_para = n.agendado_para and o.story_rodizio_de = n.story_rodizio_de, 'D: divergiu';
  -- limpa pro resto
  delete from posta_ai.post_captions where post_id in (select id from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story');
  delete from posta_ai.post_assets where post_id in (select id from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story');
  delete from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story';
  raise notice 'OK T2 rodízio idêntico ao de produção (4 cenários)';
end $$;

-- ---------- T3: marca sem horário de rodízio não ganha rodízio; mídia apagada não é fonte ----------
do $$
begin
  assert posta_ai.enfileirar_story_diario('dddddddd-0000-4000-8000-00000000000d') is null, 'L sem horário criou story';
  update posta_ai.post_assets set midia_removida_em = now() where post_id in (select id from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a');
  assert posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a') is null, 'usou mídia apagada';
  update posta_ai.post_assets set midia_removida_em = null where post_id in (select id from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a');
  raise notice 'OK T3 sem horário = sem rodízio; mídia apagada fora';
end $$;

-- ---------- T4: dois horários de rodízio no mesmo dia ----------
do $$
declare v_tz text; v_h1 time; v_h2 time; v_qtd int; v_fontes int;
begin
  -- fuso em que agora + 1h e + 2h caem no mesmo dia local
  select tz into v_tz from unnest(array['UTC','Asia/Tokyo','America/Los_Angeles','Pacific/Auckland']) tz
   where extract(hour from now() at time zone tz) between 1 and 20 limit 1;
  v_h1 := date_trunc('minute', (now() at time zone v_tz) + interval '1 hour')::time;
  v_h2 := date_trunc('minute', (now() at time zone v_tz) + interval '2 hours')::time;
  update posta_ai.brands set timezone = v_tz where id = 'aaaaaaaa-0000-4000-8000-00000000000a';
  delete from posta_ai.story_horarios where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a';
  insert into posta_ai.story_horarios (brand_id, tipo, hora) values
    ('aaaaaaaa-0000-4000-8000-00000000000a', 'rodizio', v_h1), ('aaaaaaaa-0000-4000-8000-00000000000a', 'rodizio', v_h2);
  perform posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a');
  select count(*), count(distinct story_rodizio_de) into v_qtd, v_fontes from posta_ai.posts
   where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story';
  assert v_qtd = 2 and v_fontes = 2, format('esperava 2 stories de 2 fontes, veio %s/%s', v_qtd, v_fontes);
  assert posta_ai.enfileirar_story_diario('aaaaaaaa-0000-4000-8000-00000000000a') is null, 'duplicou';
  -- volta a G pro estado de produção
  delete from posta_ai.post_captions where post_id in (select id from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story');
  delete from posta_ai.post_assets where post_id in (select id from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story');
  delete from posta_ai.posts where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a' and formato = 'story';
  delete from posta_ai.story_horarios where brand_id = 'aaaaaaaa-0000-4000-8000-00000000000a';
  insert into posta_ai.story_horarios (brand_id, tipo, hora) values ('aaaaaaaa-0000-4000-8000-00000000000a', 'rodizio', '12:00');
  update posta_ai.brands set timezone = 'America/Los_Angeles' where id = 'aaaaaaaa-0000-4000-8000-00000000000a';
  raise notice 'OK T4 dois horários de rodízio = dois stories, fontes diferentes, idempotente';
end $$;

-- ---------- T5: próximo horário de repost (seg-sex 12:00 Recife) ----------
do $$
begin
  -- sexta 09/10/2026 19:00 Recife → segunda 12/10 12:00 Recife (15:00 UTC)
  assert posta_ai.proximo_horario_livre('cccccccc-0000-4000-8000-00000000000c', 'repost', '2026-10-09 22:00+00')
       = '2026-10-12 15:00+00', 'sexta → segunda falhou';
  -- terça 06/10 18:00 Recife → quarta 07/10 12:00
  assert posta_ai.proximo_horario_livre('cccccccc-0000-4000-8000-00000000000c', 'repost', '2026-10-06 21:00+00')
       = '2026-10-07 15:00+00', 'terça → quarta falhou';
  -- quarta ocupada → quinta
  insert into posta_ai.posts (brand_id, formato, status, agendado_para) values
    ('cccccccc-0000-4000-8000-00000000000c', 'story', 'agendado', '2026-10-07 15:00+00');
  assert posta_ai.proximo_horario_livre('cccccccc-0000-4000-8000-00000000000c', 'repost', '2026-10-06 21:00+00')
       = '2026-10-08 15:00+00', 'não pulou o ocupado';
  delete from posta_ai.posts where brand_id = 'cccccccc-0000-4000-8000-00000000000c';
  -- marca sem horário de repost → NULL
  assert posta_ai.proximo_horario_livre('dddddddd-0000-4000-8000-00000000000d', 'repost', now()) is null;
  raise notice 'OK T5 próximo horário de repost';
end $$;

-- ---------- T6: cross-post IG + FB, legenda do FB, finalização e companheiro ----------
do $$
declare j record; v text; v_post uuid := 'c0000000-0000-4000-8000-000000000001'; v_comp record;
begin
  insert into posta_ai.posts (id, brand_id, titulo_interno, formato, status, agendado_para)
  values (v_post, 'cccccccc-0000-4000-8000-00000000000c', 'Feed C', 'feed', 'agendado', now() - interval '1 minute');
  insert into posta_ai.post_assets (post_id, ordem, tipo, url) values (v_post, 0, 'imagem', 'https://x/storage/v1/object/public/posta-ai-media/c/f.png');
  insert into posta_ai.post_captions (post_id, versao, corpo, corpo_fb) values (v_post, 1, 'legenda ig', 'legenda fb');
  insert into posta_ai.post_captions (post_id, versao, corpo) values (v_post, 2, 'legenda ig v2');

  select * into j from public.rpc_proximo_job_publicacao();
  assert j.post_id = v_post and j.canal = 'instagram' and j.conta_id = 'IG_C', 'IG não veio primeiro';
  assert j.token = 'token-falso-de-teste' and j.media_type = 'IMAGE';
  assert j.caption = E'legenda ig v2\n\n#certoagro', 'legenda IG: ' || j.caption;
  assert (select count(*) from posta_ai.publish_jobs where post_id = v_post) = 2, 'não nasceu 1 job por canal';
  assert (select status from posta_ai.posts where id = v_post) = 'publicando';
  v := public.rpc_marcar_resultado_job(j.job_id, true, 'CR1', 'M1');
  assert v = 'aguardando', 'fechou antes do FB: ' || v;

  select * into j from public.rpc_proximo_job_publicacao();
  assert j.post_id = v_post and j.canal = 'facebook' and j.conta_id = 'PG_C', 'FB não veio em seguida';
  assert j.caption = E'legenda fb\n\n#certoagro', 'legenda FB: ' || j.caption;
  v := public.rpc_marcar_resultado_job(j.job_id, true, null, null, 'PH1', 'PG_C_123');
  assert v = 'publicado', 'final: ' || v;
  assert (select fb_post_id from posta_ai.publish_jobs where id = j.job_id) = 'PG_C_123';
  assert (select count(*) from posta_ai.post_events where post_id = v_post and para_status = 'publicado' and autor = 'sistema') = 1;
  -- marcar de novo é ignorado (nunca reabre)
  assert public.rpc_marcar_resultado_job(j.job_id, false, p_erro => 'x') = 'ignorado';

  select * into v_comp from posta_ai.posts where post_origem_id = v_post;
  assert v_comp.id is not null and v_comp.formato = 'story' and v_comp.status = 'agendado', 'sem companheiro';
  assert v_comp.agendado_para = posta_ai.proximo_horario_livre('cccccccc-0000-4000-8000-00000000000c', 'repost', now())
      or (v_comp.agendado_para at time zone 'America/Recife')::time = '12:00', 'companheiro fora do horário de repost';
  assert extract(isodow from v_comp.agendado_para at time zone 'America/Recife') between 1 and 5, 'repost no fim de semana';
  assert not exists (select 1 from public.rpc_proximo_job_publicacao()), 'fila não secou';
  raise notice 'OK T6 cross-post IG+FB, legenda FB, finalização, companheiro no repost (%)', v_comp.agendado_para;
end $$;

-- ---------- T7: falha parcial e falha total ----------
do $$
declare j record; v text; p1 uuid := 'c0000000-0000-4000-8000-000000000002'; p2 uuid := 'c0000000-0000-4000-8000-000000000003';
begin
  insert into posta_ai.posts (id, brand_id, titulo_interno, formato, status, agendado_para) values
    (p1, 'cccccccc-0000-4000-8000-00000000000c', 'Parcial', 'feed', 'agendado', now() - interval '3 minutes'),
    (p2, 'cccccccc-0000-4000-8000-00000000000c', 'Total',   'reel', 'agendado', now() - interval '2 minutes');
  insert into posta_ai.post_assets (post_id, ordem, tipo, url) values (p1, 0, 'imagem', 'https://x/a.png'), (p2, 0, 'video', 'https://x/b.mp4');
  -- p1: IG falha, FB publica → publicado (parcial)
  select * into j from public.rpc_proximo_job_publicacao(); assert j.post_id = p1 and j.canal = 'instagram';
  perform public.rpc_marcar_resultado_job(j.job_id, false, p_erro => 'ig caiu');
  select * into j from public.rpc_proximo_job_publicacao(); assert j.post_id = p1 and j.canal = 'facebook', 'pendente do p1 não teve prioridade';
  v := public.rpc_marcar_resultado_job(j.job_id, true, p_fb_post_id => 'X');
  assert v = 'publicado' and (select status from posta_ai.posts where id = p1) = 'publicado';
  -- p2: os dois falham → falhou, sem companheiro
  select * into j from public.rpc_proximo_job_publicacao(); assert j.post_id = p2 and j.media_type = 'REELS';
  perform public.rpc_marcar_resultado_job(j.job_id, false, p_erro => 'e1');
  select * into j from public.rpc_proximo_job_publicacao(); assert j.post_id = p2 and j.canal = 'facebook';
  v := public.rpc_marcar_resultado_job(j.job_id, false, p_erro => 'e2');
  assert v = 'falhou' and (select status from posta_ai.posts where id = p2) = 'falhou';
  assert not exists (select 1 from posta_ai.posts where post_origem_id = p2), 'companheiro de post falho';
  raise notice 'OK T7 parcial = publicado; total = falhou sem companheiro';
end $$;

-- ---------- T8: marca só IG (como Gigi/Luh Panda hoje) segue igual ----------
do $$
declare j record; v text; p uuid := 'd0000000-0000-4000-8000-000000000001'; c record;
begin
  insert into posta_ai.posts (id, brand_id, titulo_interno, formato, status, agendado_para)
  values (p, 'dddddddd-0000-4000-8000-00000000000d', 'Reel L', 'reel', 'agendado', now() - interval '1 minute');
  insert into posta_ai.post_assets (post_id, ordem, tipo, url) values (p, 0, 'video', 'https://x/l.mp4');
  select * into j from public.rpc_proximo_job_publicacao();
  assert j.canal = 'instagram' and (select count(*) from posta_ai.publish_jobs where post_id = p) = 1, 'marca só IG ganhou job FB';
  v := public.rpc_marcar_resultado_job(j.job_id, true, 'C', 'M');
  assert v = 'publicado';
  select * into c from posta_ai.posts where post_origem_id = p;
  assert c.agendado_para = (select agendado_para from posta_ai.posts where id = p) + interval '1 day', 'companheiro saiu do D+1';
  raise notice 'OK T8 marca só IG: 1 job, companheiro D+1 como antes';
end $$;

-- ---------- T9: erros de cadastro viram falha limpa ----------
do $$
declare p uuid := 'c0000000-0000-4000-8000-000000000009';
begin
  update posta_ai.social_accounts set page_id = '' where brand_id = 'cccccccc-0000-4000-8000-00000000000c';
  insert into posta_ai.posts (id, brand_id, formato, status, agendado_para) values (p, 'cccccccc-0000-4000-8000-00000000000c', 'feed', 'agendado', now() - interval '1 minute');
  insert into posta_ai.post_assets (post_id, ordem, tipo, url) values (p, 0, 'imagem', 'https://x/z.png');
  assert not exists (select 1 from public.rpc_proximo_job_publicacao());
  assert (select status from posta_ai.posts where id = p) = 'falhou';
  assert (select erro from posta_ai.publish_jobs where post_id = p) like 'publicar_facebook ligado%';
  update posta_ai.social_accounts set page_id = 'PG_C' where brand_id = 'cccccccc-0000-4000-8000-00000000000c';
  raise notice 'OK T9 FB ligado sem page_id = falha explicada';
end $$;

-- ---------- T10: ceifador mede de iniciado_em e fecha por lote ----------
do $$
declare j record; p uuid := 'c0000000-0000-4000-8000-000000000010'; n int;
begin
  insert into posta_ai.posts (id, brand_id, titulo_interno, formato, status, agendado_para) values (p, 'cccccccc-0000-4000-8000-00000000000c', 'Ceifa', 'feed', 'agendado', now() - interval '1 minute');
  insert into posta_ai.post_assets (post_id, ordem, tipo, url) values (p, 0, 'imagem', 'https://x/c.png');
  select * into j from public.rpc_proximo_job_publicacao();
  perform public.rpc_marcar_resultado_job(j.job_id, true, 'c', 'm');
  -- o job do FB nasceu há 30 min mas NÃO começou → não é órfão
  update posta_ai.publish_jobs set criado_em = now() - interval '30 minutes' where post_id = p;
  n := posta_ai.ceifar_jobs_orfaos();
  assert n = 0, 'ceifou job pendente';
  select * into j from public.rpc_proximo_job_publicacao();
  assert j.canal = 'facebook';
  -- começou há 25 min e morreu → órfão; IG publicou → post publicado
  update posta_ai.publish_jobs set iniciado_em = now() - interval '25 minutes' where id = j.job_id;
  n := posta_ai.ceifar_jobs_orfaos();
  assert n = 1;
  assert (select status from posta_ai.posts where id = p) = 'publicado', 'post não fechou como publicado';
  assert (select erro from posta_ai.publish_jobs where id = j.job_id) like '%Página do Facebook%';
  raise notice 'OK T10 ceifador por lote';
end $$;

-- ---------- T11: automação (n8n) ----------
insert into posta_ai.automacoes (brand_id, nome, segredo_sha256, formatos, molde_aprovado, url_base_midia) values
  ('cccccccc-0000-4000-8000-00000000000c', 'teste-cotacao', encode(extensions.digest('segredo-certo', 'sha256'), 'hex'), '{story}', true, 'https://x/storage/v1/object/public/posta-ai-media/cccccccc-0000-4000-8000-00000000000c/'),
  ('cccccccc-0000-4000-8000-00000000000c', 'teste-um-a-um', encode(extensions.digest('outro', 'sha256'), 'hex'), '{feed}', false, 'https://x/storage/v1/object/public/posta-ai-media/cccccccc-0000-4000-8000-00000000000c/');
do $$
declare r jsonb; r2 jsonb; ok boolean; base text := 'https://x/storage/v1/object/public/posta-ai-media/cccccccc-0000-4000-8000-00000000000c/';
begin
  -- sem header → negado
  perform set_config('request.headers', '{}', true);
  begin perform public.posta_ai_automacao_criar_post('teste-cotacao', 'k1', 't', 'story', now() + interval '1 hour', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'a.png'))); ok := false;
  exception when insufficient_privilege then ok := true; end; assert ok, 'sem segredo passou';
  -- segredo errado → negado; automação inexistente → mesmo erro
  perform set_config('request.headers', '{"x-automacao-secret":"errado"}', true);
  begin perform public.posta_ai_automacao_criar_post('teste-cotacao', 'k1', 't', 'story', now() + interval '1 hour', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'a.png'))); ok := false;
  exception when insufficient_privilege then ok := true; end; assert ok, 'segredo errado passou';
  perform set_config('request.headers', '{"x-automacao-secret":"segredo-certo"}', true);
  begin perform public.posta_ai_automacao_criar_post('nao-existe', 'k1', 't', 'story', now() + interval '1 hour', '[]'); ok := false;
  exception when insufficient_privilege then ok := true; end; assert ok, 'automação inexistente deu erro diferente';
  -- formato fora / URL fora da pasta / janela
  begin perform public.posta_ai_automacao_criar_post('teste-cotacao', 'k1', 't', 'feed', now() + interval '1 hour', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'a.png'))); ok := false;
  exception when invalid_parameter_value then ok := true; end; assert ok, 'formato fora passou';
  begin perform public.posta_ai_automacao_criar_post('teste-cotacao', 'k1', 't', 'story', now() + interval '1 hour', jsonb_build_array(jsonb_build_object('tipo','imagem','url','https://evil/a.png'))); ok := false;
  exception when invalid_parameter_value then ok := true; end; assert ok, 'URL de fora passou';
  begin perform public.posta_ai_automacao_criar_post('teste-cotacao', 'k1', 't', 'story', now() - interval '1 hour', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'a.png'))); ok := false;
  exception when invalid_parameter_value then ok := true; end; assert ok, 'passado passou';
  -- certo → agendado direto (molde aprovado), idempotente
  r := public.posta_ai_automacao_criar_post('teste-cotacao', 'cotacao-2026-10-07', 'Cotação 07/10', 'story', now() + interval '1 hour', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'a.png')), 'legenda');
  assert (r ->> 'criado')::boolean and r ->> 'status' = 'agendado', r::text;
  r2 := public.posta_ai_automacao_criar_post('teste-cotacao', 'cotacao-2026-10-07', 'x', 'story', now() + interval '2 hours', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'b.png')));
  assert r2 ->> 'post_id' = r ->> 'post_id' and not (r2 ->> 'criado')::boolean, 'duplicou';
  assert (select count(*) from posta_ai.post_events where post_id = (r ->> 'post_id')::uuid and autor = 'automacao:teste-cotacao' and para_status = 'agendado') = 1;
  assert (select tipo from posta_ai.post_assets where post_id = (r ->> 'post_id')::uuid) = 'imagem';
  -- molde NÃO aprovado → em_aprovacao
  perform set_config('request.headers', '{"x-automacao-secret":"outro"}', true);
  r := public.posta_ai_automacao_criar_post('teste-um-a-um', 'k', 't', 'feed', now() + interval '1 day', jsonb_build_array(jsonb_build_object('tipo','imagem','url', base || 'c.png')));
  assert r ->> 'status' = 'em_aprovacao';
  raise notice 'OK T11 automação: auth, travas, idempotência, molde aprovado x um a um';
end $$;

-- ---------- T12: limpeza de Storage ----------
do $$
declare ok boolean; v_qtd int; base text := 'https://x/storage/v1/object/public/posta-ai-media/';
begin
  begin perform * from public.rpc_midia_expirada(29); ok := false; exception when invalid_parameter_value then ok := true; end;
  assert ok, 'aceitou menos de 30 dias';
  -- L: reel publicado há 40 dias (expira) + carrossel publicado há 40 dias usado por story agendado (não expira)
  insert into posta_ai.posts (id, brand_id, formato, status) values
    ('d0000000-0000-4000-8000-0000000000a1', 'dddddddd-0000-4000-8000-00000000000d', 'reel', 'publicado'),
    ('d0000000-0000-4000-8000-0000000000a2', 'dddddddd-0000-4000-8000-00000000000d', 'feed', 'publicado'),
    ('d0000000-0000-4000-8000-0000000000a3', 'dddddddd-0000-4000-8000-00000000000d', 'story', 'agendado'),
    ('d0000000-0000-4000-8000-0000000000a4', 'dddddddd-0000-4000-8000-00000000000d', 'feed', 'publicado');
  insert into posta_ai.post_assets (post_id, ordem, tipo, url) values
    ('d0000000-0000-4000-8000-0000000000a1', 0, 'video', base || 'l/velho.mp4'),
    ('d0000000-0000-4000-8000-0000000000a2', 0, 'imagem', base || 'l/em-uso.png'),
    ('d0000000-0000-4000-8000-0000000000a3', 0, 'imagem', base || 'l/em-uso.png'),
    ('d0000000-0000-4000-8000-0000000000a4', 0, 'imagem', base || 'l/recente.png');
  insert into posta_ai.publish_jobs (post_id, status, publicado_em) values
    ('d0000000-0000-4000-8000-0000000000a1', 'publicado', now() - interval '40 days'),
    ('d0000000-0000-4000-8000-0000000000a2', 'publicado', now() - interval '40 days'),
    ('d0000000-0000-4000-8000-0000000000a4', 'publicado', now() - interval '10 days');
  -- G: reel publicado há 40 dias, marca com rodízio → protegido
  insert into posta_ai.publish_jobs (post_id, status, publicado_em) values ('a0000000-0000-4000-8000-000000000001', 'publicado', now() - interval '40 days');
  update posta_ai.posts set atualizado_em = now() - interval '40 days' where id = 'a0000000-0000-4000-8000-000000000001';

  assert exists (select 1 from public.rpc_midia_expirada(30) where url = base || 'l/velho.mp4'), 'velho não listado';
  assert not exists (select 1 from public.rpc_midia_expirada(30) where url = base || 'l/em-uso.png'), 'listou mídia em uso por story agendado';
  assert not exists (select 1 from public.rpc_midia_expirada(30) where url = base || 'l/recente.png'), 'listou recente';
  assert not exists (select 1 from public.rpc_midia_expirada(30) where url like '%/g/r1.mp4'), 'listou mídia do rodízio da G';
  assert (select existe_no_storage from public.rpc_midia_expirada(30) where url = base || 'l/velho.mp4') = false;
  v_qtd := public.rpc_marcar_midia_removida(array[base || 'l/velho.mp4']);
  assert v_qtd = 1;
  assert not exists (select 1 from public.rpc_midia_expirada(30) where url = base || 'l/velho.mp4'), 'marcada continua listada';
  raise notice 'OK T12 limpeza: 30 dias, em uso fica, rodízio fica, marcação';
end $$;

rollback;
\echo 'TODOS OS TESTES PASSARAM (rollback feito, nada gravado)'
