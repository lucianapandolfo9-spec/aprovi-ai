-- aprovi.ai — migration 9 (27/11/2026): escolha de canais POR POST (decisão D7).
--
-- Luciana, 27/11: cada post mostra as redes ligadas na marca, já marcadas; a equipe
-- (painel) e a cliente (link de aprovação) podem desmarcar. Grava em
-- posts.canais_desligados, que a fila já respeita desde a migration 7.
--
-- Aditiva, exceto UM ajuste: gerar_story_companheiro (story auto 24 h depois do reel)
--   - não cria story se a marca não publica em IG nem FB (story não vai para TikTok/YouTube);
--   - herda os canais desligados do post de origem e não cria se IG e FB estavam desligados nele.
-- Achado no teste de 27/11: a marca de teste (só TikTok) ganhou um story auto que ia falhar.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Canais que a MARCA oferece para um formato (antes do que o post desligou)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function posta_ai.canais_da_marca(p_brand_id uuid, p_formato text)
 returns text[]
 language sql
 stable
 security definer
 set search_path to 'posta_ai', 'public'
as $function$
  select coalesce(array_agg(c order by array_position(array['instagram','facebook','tiktok','youtube'], c)), '{}')
  from (
    select 'instagram' c from posta_ai.social_accounts sa
     where sa.brand_id = p_brand_id and sa.publicar_instagram and coalesce(sa.ig_user_id, '') <> ''
    union
    select 'facebook' from posta_ai.social_accounts sa
     where sa.brand_id = p_brand_id and sa.publicar_facebook and coalesce(sa.page_id, '') <> ''
    union
    select cr.rede from posta_ai.contas_rede cr
     where cr.brand_id = p_brand_id and cr.ativo and cr.publicar_por_padrao and p_formato = 'reel'
  ) x;
$function$;
revoke all on function posta_ai.canais_da_marca(uuid, text) from public, anon, authenticated;

-- Valida a lista de desligados e devolve o que sobra ligado. Lança se não sobrar nada.
create or replace function posta_ai.validar_desligados(p_possiveis text[], p_desligados text[])
 returns text[]
 language plpgsql
 immutable
 set search_path to 'posta_ai', 'public'
as $function$
declare v_resta text[];
begin
  if exists (select 1 from unnest(coalesce(p_desligados, '{}')) d
             where d not in ('instagram','facebook','tiktok','youtube')) then
    raise exception 'canal invalido';
  end if;
  select coalesce(array_agg(c), '{}') into v_resta
  from unnest(p_possiveis) c where not (c = any(coalesce(p_desligados, '{}')));
  if cardinality(v_resta) = 0 then
    raise exception 'deixe pelo menos uma rede marcada';
  end if;
  return v_resta;
end;
$function$;
revoke all on function posta_ai.validar_desligados(text[], text[]) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Painel (admin)
-- ─────────────────────────────────────────────────────────────────────────────
-- Por post: o que pode, o que foi desligado e o resultado de cada canal (último job).
create or replace function public.posta_ai_admin_canais_posts(p_brand_id uuid)
 returns table(post_id uuid, canais_possiveis text[], canais_desligados text[], resultados jsonb)
 language sql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
  select p.id,
         posta_ai.canais_da_marca(p.brand_id, p.formato),
         coalesce(p.canais_desligados, '{}'),
         (select coalesce(jsonb_object_agg(j.canal, jsonb_build_object('status', j.status, 'visibilidade', j.visibilidade)), '{}'::jsonb)
            from (select distinct on (canal) canal, status, visibilidade
                    from posta_ai.publish_jobs
                   where publish_jobs.post_id = p.id and canal is not null
                   order by canal, criado_em desc) j)
  from posta_ai.posts p
  where p.brand_id = p_brand_id and public.posta_ai_is_admin();
$function$;

create or replace function public.posta_ai_admin_set_canais_post(p_post_id uuid, p_desligados text[])
 returns text[]
 language plpgsql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
declare v_p posta_ai.posts; v_resta text[];
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  select * into v_p from posta_ai.posts where id = p_post_id;
  if not found then raise exception 'post nao encontrado'; end if;
  if v_p.status in ('publicando', 'publicado') then raise exception 'post ja saiu: nao da para mudar as redes'; end if;
  v_resta := posta_ai.validar_desligados(posta_ai.canais_da_marca(v_p.brand_id, v_p.formato), p_desligados);
  update posta_ai.posts set canais_desligados = coalesce(p_desligados, '{}'), atualizado_em = now() where id = p_post_id;
  return v_resta;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Link de aprovação (cliente, autorizada pelo token da marca)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.posta_ai_client_canais_posts(p_token text)
 returns table(post_id uuid, canais_possiveis text[], canais_desligados text[])
 language plpgsql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
declare v_brand uuid;
begin
  v_brand := public.posta_ai_brand_from_token(p_token);
  if v_brand is null then raise exception 'invalid token'; end if;
  return query
  select p.id, posta_ai.canais_da_marca(p.brand_id, p.formato), coalesce(p.canais_desligados, '{}')
  from posta_ai.posts p
  where p.brand_id = v_brand and p.status <> 'rascunho';
end;
$function$;

create or replace function public.posta_ai_client_set_canais_post(p_token text, p_post_id uuid, p_desligados text[])
 returns text[]
 language plpgsql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
declare v_brand uuid; v_p posta_ai.posts; v_resta text[];
begin
  v_brand := public.posta_ai_brand_from_token(p_token);
  if v_brand is null then raise exception 'invalid token'; end if;
  select * into v_p from posta_ai.posts where id = p_post_id;
  if not found or v_p.brand_id <> v_brand then raise exception 'post not found for this brand'; end if;
  if v_p.status not in ('em_aprovacao', 'ajuste_pedido') then
    raise exception 'so da para mudar as redes enquanto o post aguarda aprovacao';
  end if;
  v_resta := posta_ai.validar_desligados(posta_ai.canais_da_marca(v_p.brand_id, v_p.formato), p_desligados);
  update posta_ai.posts set canais_desligados = coalesce(p_desligados, '{}'), atualizado_em = now() where id = p_post_id;
  insert into posta_ai.post_events (post_id, de_status, para_status, autor)
  values (p_post_id, v_p.status, v_p.status, 'aprovador');
  return v_resta;
end;
$function$;

revoke all on function public.posta_ai_admin_canais_posts(uuid) from public, anon;
revoke all on function public.posta_ai_admin_set_canais_post(uuid, text[]) from public, anon;
grant execute on function public.posta_ai_admin_canais_posts(uuid) to authenticated;
grant execute on function public.posta_ai_admin_set_canais_post(uuid, text[]) to authenticated;
-- cliente não tem login: as duas usam o token da marca, como posta_ai_client_feed/_decide
revoke all on function public.posta_ai_client_canais_posts(text) from public;
revoke all on function public.posta_ai_client_set_canais_post(text, uuid, text[]) from public;
grant execute on function public.posta_ai_client_canais_posts(text) to anon, authenticated;
grant execute on function public.posta_ai_client_set_canais_post(text, uuid, text[]) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Story auto: só quando faz sentido (ajuste da função existente)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function posta_ai.gerar_story_companheiro(p_post_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'public'
as $function$
declare
  v_brand_id uuid;
  v_formato text;
  v_agendado_para timestamptz;
  v_titulo text;
  v_desligados text[];
  v_quando timestamptz;
  v_story_id uuid;
  v_asset record;
  v_corpo text;
begin
  select brand_id, formato, agendado_para, titulo_interno, coalesce(canais_desligados, '{}')
  into v_brand_id, v_formato, v_agendado_para, v_titulo, v_desligados
  from posta_ai.posts
  where id = p_post_id;

  if v_formato not in ('reel', 'feed')
     or exists (select 1 from posta_ai.posts where post_origem_id = p_post_id) then
    return null;
  end if;

  -- 27/11/2026: story só sai em IG/FB. Sem nenhum dos dois ligado (na marca e no post), não cria.
  if not exists (
    select 1 from unnest(posta_ai.canais_da_marca(v_brand_id, 'story')) c
    where not (c = any(v_desligados))
  ) then
    return null;
  end if;

  v_quando := posta_ai.proximo_horario_livre(v_brand_id, 'repost', now());
  if v_quando is null then
    v_quando := v_agendado_para + interval '1 day';
  end if;

  insert into posta_ai.posts (brand_id, titulo_interno, formato, status, agendado_para, post_origem_id, canais_desligados)
  values (v_brand_id, v_titulo || ' — Story (auto)', 'story', 'agendado', v_quando, p_post_id,
          array(select d from unnest(v_desligados) d where d in ('instagram', 'facebook')))
  returning id into v_story_id;

  select ordem, tipo, url, duracao_seg into v_asset
  from posta_ai.post_assets
  where post_id = p_post_id
  order by ordem asc
  limit 1;

  insert into posta_ai.post_assets (post_id, ordem, tipo, url, duracao_seg)
  values (v_story_id, 0, v_asset.tipo, v_asset.url, v_asset.duracao_seg);

  select corpo into v_corpo
  from posta_ai.post_captions
  where post_id = p_post_id
  order by versao desc
  limit 1;

  if v_corpo is not null then
    insert into posta_ai.post_captions (post_id, versao, corpo, autor)
    values (v_story_id, 1, v_corpo, 'auto');
  end if;

  return v_story_id;
end;
$function$;
