-- aprovi.ai — migration 10 (27/11/2026): story de vídeo longo não vai para o Instagram.
--
-- Causa das falhas do Certo Agro (16, 17, 23, 25, 26/11): o Instagram só aceita story de vídeo
-- com até 60 s pela API. Os 4 vídeos que falhavam têm 61,4 a 67,5 s (vacinas, tutorial
-- lançar rápido, Seu Antônio ep. 1 e ep. 3); o Facebook aceita e publicava. Os outros 60 vídeos
-- (todos até 60 s) sempre saíram.
--
-- 1. limite_story_ig_seg(): 60.
-- 2. Rodízio (enfileirar_story_diario): só escolhe vídeo com duração conhecida <= 60 s, ou sem
--    duração gravada (compatível). A duração de todos os vídeos foi preenchida em 27/11 (ffprobe).
-- 3. Story auto do reel (gerar_story_companheiro): vídeo > 60 s vira story só no Facebook
--    (instagram entra em canais_desligados); se a marca não tem Facebook, não cria o story.
-- 4. Fila (rpc_proximo_job_publicacao) não muda: ela já respeita canais_desligados.

create or replace function posta_ai.limite_story_ig_seg()
 returns integer language sql immutable as $$ select 60 $$;
revoke all on function posta_ai.limite_story_ig_seg() from public, anon, authenticated;

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

  select ordem, tipo, url, duracao_seg into v_asset
  from posta_ai.post_assets
  where post_id = p_post_id
  order by ordem asc
  limit 1;

  -- 27/11/2026 (migration 10): story de vídeo com mais de 60 s não entra no Instagram
  -- (a Graph API recusa: 2207032 / status ERROR). Sai só no Facebook; se não sobrar canal, não cria.
  if v_asset.tipo = 'video' and coalesce(v_asset.duracao_seg, 0) > posta_ai.limite_story_ig_seg() then
    v_desligados := array(select distinct d from unnest(v_desligados || array['instagram']) d);
    if not exists (
      select 1 from unnest(posta_ai.canais_da_marca(v_brand_id, 'story')) c
      where not (c = any(v_desligados))
    ) then
      return null;
    end if;
  end if;

  v_quando := posta_ai.proximo_horario_livre(v_brand_id, 'repost', now());
  if v_quando is null then
    v_quando := v_agendado_para + interval '1 day';
  end if;

  insert into posta_ai.posts (brand_id, titulo_interno, formato, status, agendado_para, post_origem_id, canais_desligados)
  values (v_brand_id, v_titulo || ' — Story (auto)', 'story', 'agendado', v_quando, p_post_id,
          array(select d from unnest(v_desligados) d where d in ('instagram', 'facebook')))
  returning id into v_story_id;

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

-- ─────────────────────────────────────────────────────────────────────────────
-- Rodízio: igual à versão em produção até 27/11, com UMA linha nova (vídeo <= 60 s).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION posta_ai.enfileirar_story_diario(p_brand_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'posta_ai', 'public'
AS $function$
declare
  v_tz           text;
  v_dia_alvo     date;
  v_qtd_horarios integer;
  v_qtd_stories  integer;
  v_slot         timestamptz;
  v_fonte        record;
  v_story_id     uuid;
  v_primeiro     uuid;
  v_corpo        text;
begin
  select timezone into v_tz from posta_ai.brands where id = p_brand_id;
  if v_tz is null then
    return null;
  end if;

  select o.dia into v_dia_alvo
  from (
    select d.dia, ((d.dia + h.hora) at time zone v_tz) as inst
    from (
      select ((now() at time zone v_tz)::date + i) as dia
      from generate_series(0, 1) as i
    ) d
    join posta_ai.story_horarios h
      on h.brand_id = p_brand_id and h.tipo = 'rodizio' and h.ativo
     and extract(isodow from d.dia)::smallint = any (h.dias_semana)
  ) o
  where o.inst > now()
  order by o.inst
  limit 1;

  if v_dia_alvo is null then
    return null;
  end if;

  select count(*) into v_qtd_horarios
  from posta_ai.story_horarios h
  where h.brand_id = p_brand_id and h.tipo = 'rodizio' and h.ativo
    and extract(isodow from v_dia_alvo)::smallint = any (h.dias_semana);

  select count(*) into v_qtd_stories
  from posta_ai.posts
  where brand_id = p_brand_id
    and formato = 'story'
    and status <> 'falhou'
    and agendado_para is not null
    and (agendado_para at time zone v_tz)::date = v_dia_alvo;

  for v_slot in
    select ((v_dia_alvo + h.hora) at time zone v_tz)
    from posta_ai.story_horarios h
    where h.brand_id = p_brand_id and h.tipo = 'rodizio' and h.ativo
      and extract(isodow from v_dia_alvo)::smallint = any (h.dias_semana)
    order by h.hora
  loop
    exit when v_qtd_stories >= v_qtd_horarios;
    continue when v_slot <= now();
    continue when exists (
      select 1 from posta_ai.posts
      where brand_id = p_brand_id and formato = 'story'
        and status <> 'falhou' and agendado_para = v_slot
    );

    select p.id, p.titulo_interno, a.tipo, a.url, a.duracao_seg
    into v_fonte
    from posta_ai.posts p
    join posta_ai.post_assets a
      on a.post_id = p.id and a.ordem = 0
    where p.brand_id = p_brand_id
      and p.formato in ('reel', 'feed')
      and p.status = 'publicado'
      and p.agendado_para <= now() - interval '3 days'
      and not p.fora_do_rodizio
      and a.tipo = 'video'
      and a.midia_removida_em is null
      and coalesce(a.duracao_seg, 0) <= posta_ai.limite_story_ig_seg()  -- 27/11: IG recusa story > 60 s
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

    exit when not found;

    insert into posta_ai.posts
      (brand_id, titulo_interno, formato, status, agendado_para, story_rodizio_de)
    values
      (p_brand_id,
       coalesce(v_fonte.titulo_interno, 'Story') || ' — Story (rodízio)',
       'story', 'agendado', v_slot, v_fonte.id)
    returning id into v_story_id;

    insert into posta_ai.post_assets (post_id, ordem, tipo, url, duracao_seg)
    values (v_story_id, 0, v_fonte.tipo, v_fonte.url, v_fonte.duracao_seg);

    select corpo into v_corpo
    from posta_ai.post_captions
    where post_id = v_fonte.id
    order by versao desc
    limit 1;

    if v_corpo is not null then
      insert into posta_ai.post_captions (post_id, versao, corpo, autor)
      values (v_story_id, 1, v_corpo, 'auto');
    end if;

    v_qtd_stories := v_qtd_stories + 1;
    v_primeiro := coalesce(v_primeiro, v_story_id);
  end loop;

  return v_primeiro;
end;
$function$;
