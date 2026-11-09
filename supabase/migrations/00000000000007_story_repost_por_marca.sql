-- Repost automático em story (story "companheiro") passa a ser opção por marca.
-- Padrão continua ligado (nada muda para as marcas existentes).
-- Palácio dos Esportes desligado em 09/11/2026: o contrato é 5 stories/semana e
-- quem posta os stories é a Luciana, à mão.

alter table posta_ai.brands
  add column if not exists story_repost_auto boolean not null default true;

comment on column posta_ai.brands.story_repost_auto is
  'Se true, cada reel/feed publicado gera um story de repost automático (gerar_story_companheiro).';

update posta_ai.brands set story_repost_auto = false
 where id = 'f539d5d8-bab9-4899-bcb4-cd54614fc738';  -- Palácio dos Esportes

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
  v_quando timestamptz;
  v_story_id uuid;
  v_asset record;
  v_corpo text;
begin
  select brand_id, formato, agendado_para, titulo_interno
  into v_brand_id, v_formato, v_agendado_para, v_titulo
  from posta_ai.posts
  where id = p_post_id;

  if v_formato not in ('reel', 'feed')
     or exists (select 1 from posta_ai.posts where post_origem_id = p_post_id) then
    return null;
  end if;

  -- marca com repost automático desligado: não gera story
  if not coalesce((select story_repost_auto from posta_ai.brands where id = v_brand_id), true) then
    return null;
  end if;

  v_quando := posta_ai.proximo_horario_livre(v_brand_id, 'repost', now());
  if v_quando is null then
    v_quando := v_agendado_para + interval '1 day';
  end if;

  insert into posta_ai.posts (brand_id, titulo_interno, formato, status, agendado_para, post_origem_id)
  values (v_brand_id, v_titulo || ' — Story (auto)', 'story', 'agendado', v_quando, p_post_id)
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

revoke all on function posta_ai.gerar_story_companheiro(uuid) from public, anon, authenticated;
