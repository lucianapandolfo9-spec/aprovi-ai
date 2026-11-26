-- TikTok e YouTube Shorts como canais da fila de publicação (grill 26/11/2026).
-- Desenho: Obvision/Luh Panda/Dev/Sistemas/aprovi.ai/TikTok e YouTube no aprovi.ai — Desenho (grill 26-11-2026).md
--
-- PRINCÍPIOS
--   * Aditiva. Instagram e Facebook continuam exatamente como estão: as RPCs que a
--     Edge Function v21 usa mantêm a MESMA assinatura. TikTok/YouTube ganham RPCs
--     próprias (rpc_dados_job_rede, rpc_marcar_resultado_job_rede, rpc_job_aguardar_confirmacao).
--   * Seguro na ordem "migration antes do deploy": job de tiktok/youtube só nasce se
--     a marca tiver conta conectada em posta_ai.contas_rede. Enquanto ninguém conectar,
--     nada muda na fila — a v21 nunca recebe um canal que não conhece.
--   * Token nunca em coluna: Vault, igual ao token da Meta.
--   * Tabelas novas: RLS ligado, zero policy (nega tudo). Acesso só por função.
--
-- DECISÕES (D3–D6 do grill)
--   D3 opções do TikTok por post   → posts.opcoes_tiktok (preenchido pelo link da cliente)
--   D4 padrão por marca + desligar → contas_rede.publicar_por_padrao + posts.canais_desligados
--   D5 textos derivados do IG      → post_captions.corpo_tiktok / titulo_youtube / descricao_youtube (null = deriva)
--   D6 ponte até a auditoria       → contas_rede.modo ('rascunho' | 'direto') no TikTok
--      YouTube: vídeo de app não auditado fica TRAVADO privado e não dá pra tornar público
--      (support.google.com/youtube/answer/7300965, conferido 26/11). Por isso o YouTube
--      de cliente fica com publicar_por_padrao=false até a auditoria sair.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Contas conectadas por OAuth (TikTok, YouTube)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists posta_ai.contas_rede (
  id                  uuid primary key default gen_random_uuid(),
  brand_id            uuid not null references posta_ai.brands(id) on delete cascade,
  rede                text not null check (rede in ('tiktok', 'youtube')),
  conta_externa_id    text not null,          -- TikTok open_id / YouTube channel id
  apelido             text,                   -- nome exibido (exigência da TikTok: mostrar a conta)
  avatar_url          text,
  token_secret_id     uuid not null,          -- vault: access token
  refresh_secret_id   uuid,                   -- vault: refresh token
  expira_em           timestamptz,            -- do access token
  refresh_expira_em   timestamptz,
  escopos             text[] not null default '{}',
  modo                text not null default 'rascunho' check (modo in ('rascunho', 'direto')),
  publicar_por_padrao boolean not null default true,
  ativo               boolean not null default true,
  conectado_em        timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  unique (brand_id, rede)
);
alter table posta_ai.contas_rede enable row level security;

comment on column posta_ai.contas_rede.modo is
  'TikTok: rascunho = video.upload (cai na caixa de entrada do app, alguém toca em postar). '
  'direto = video.publish (só depois da auditoria; antes dela sai SELF_ONLY). YouTube ignora.';

-- Estado do OAuth (anti-CSRF): nasce no painel, é consumido uma vez pela Edge Function.
create table if not exists posta_ai.oauth_estados (
  state       text primary key,
  brand_id    uuid not null references posta_ai.brands(id) on delete cascade,
  rede        text not null check (rede in ('tiktok', 'youtube')),
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null default now() + interval '15 minutes',
  usado_em    timestamptz
);
alter table posta_ai.oauth_estados enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Post: canais desligados e opções do TikTok
-- ─────────────────────────────────────────────────────────────────────────────
alter table posta_ai.posts
  add column if not exists canais_desligados text[] not null default '{}',
  add column if not exists opcoes_tiktok jsonb;

comment on column posta_ai.posts.opcoes_tiktok is
  'Escolha da cliente no link de aprovação (exigência da TikTok): '
  '{privacy_level, disable_comment, disable_duet, disable_stitch, brand_content_toggle, '
  'brand_organic_toggle, music_consent, confirmado_em}. Só obrigatório no modo direto.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Textos por canal (null = deriva da legenda do IG)
-- ─────────────────────────────────────────────────────────────────────────────
alter table posta_ai.post_captions
  add column if not exists corpo_tiktok text,
  add column if not exists titulo_youtube text,
  add column if not exists descricao_youtube text;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Jobs: canais novos + resultado genérico + 2 fases
-- ─────────────────────────────────────────────────────────────────────────────
alter table posta_ai.publish_jobs drop constraint if exists publish_jobs_canal_check;
alter table posta_ai.publish_jobs add constraint publish_jobs_canal_check
  check (canal = any (array['instagram', 'facebook', 'tiktok', 'youtube']));

alter table posta_ai.publish_jobs
  add column if not exists externo_id    text,     -- TikTok publish_id / YouTube video id
  add column if not exists externo_url   text,
  add column if not exists etapa         text check (etapa in ('confirmar')),
  add column if not exists confirmacoes  integer not null default 0,
  add column if not exists visibilidade  text check (visibilidade in ('publico', 'privado', 'rascunho'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Fila: rpc_proximo_job_publicacao (MESMA assinatura da v4)
--    Mudanças: respeita posts.canais_desligados e cria jobs de tiktok/youtube para
--    vídeo único (reel), quando a marca tem conta ativa com publicar_por_padrao.
--    Para tiktok/youtube devolve conta_id/token NULL: a Edge Function busca o
--    resto em rpc_dados_job_rede (assim a v21 não precisa mudar de contrato).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.rpc_proximo_job_publicacao()
 returns table(job_id uuid, post_id uuid, canal text, conta_id text, token text, caption text, media_type text, assets jsonb)
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'vault', 'public'
as $function$
declare
  v_job_id uuid;
  v_post_id uuid;
  v_canal text;
  v_brand_id uuid;
  v_formato text;
  v_lote uuid;
  v_ig text;
  v_page text;
  v_secret uuid;
  v_pub_ig boolean;
  v_pub_fb boolean;
  v_tem_sa boolean;
  v_desligados text[];
  v_redes text[];
  v_token text;
  v_assets jsonb;
  v_qtd int;
  v_tipo_primeiro text;
  v_corpo text;
  v_corpo_fb text;
  v_assinatura text;
  v_legenda text;
  v_media_type text;
  v_erro text;
  v_rede text;
begin
  -- 1) próximo job pendente de um lote em andamento (2º canal, ou fase de confirmação)
  with c as (
    select j.id
    from posta_ai.publish_jobs j
    join posta_ai.posts p on p.id = j.post_id
    where j.status = 'pendente'
      and j.lote is not null
      and p.status = 'publicando'
    order by j.criado_em asc, (j.canal <> 'instagram') asc
    limit 1
    for update of j skip locked
  )
  update posta_ai.publish_jobs j
     set status = 'em_andamento', iniciado_em = now()
    from c
   where j.id = c.id
  returning j.id, j.post_id, j.canal into v_job_id, v_post_id, v_canal;

  if v_job_id is not null then
    select p.brand_id, p.formato into v_brand_id, v_formato
    from posta_ai.posts p where p.id = v_post_id;

    select sa.ig_user_id, sa.page_id, sa.token_secret_id
    into v_ig, v_page, v_secret
    from posta_ai.social_accounts sa
    where sa.brand_id = v_brand_id
    limit 1;
  else
    -- 2) próximo post agendado vencido
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
    returning p.id, p.brand_id, p.formato, p.canais_desligados
    into v_post_id, v_brand_id, v_formato, v_desligados;

    if v_post_id is null then
      return;
    end if;

    v_desligados := coalesce(v_desligados, '{}');

    select true, sa.ig_user_id, sa.page_id, sa.token_secret_id,
           sa.publicar_instagram, sa.publicar_facebook
    into v_tem_sa, v_ig, v_page, v_secret, v_pub_ig, v_pub_fb
    from posta_ai.social_accounts sa
    where sa.brand_id = v_brand_id
    limit 1;

    v_pub_ig := coalesce(v_pub_ig, false) and not ('instagram' = any(v_desligados));
    v_pub_fb := coalesce(v_pub_fb, false) and not ('facebook'  = any(v_desligados));

    -- TikTok e YouTube: só vídeo único (reel). Story/feed/carrossel ficam no IG/FB.
    select coalesce(array_agg(cr.rede order by cr.rede), '{}')
    into v_redes
    from posta_ai.contas_rede cr
    where cr.brand_id = v_brand_id
      and cr.ativo
      and cr.publicar_por_padrao
      and not (cr.rede = any(v_desligados))
      and v_formato = 'reel';

    if v_pub_ig and coalesce(v_ig, '') = '' then
      v_erro := 'publicar_instagram ligado, mas a marca nao tem ig_user_id';
    elsif v_pub_fb and coalesce(v_page, '') = '' then
      v_erro := 'publicar_facebook ligado, mas a marca nao tem page_id';
    elsif not v_pub_ig and not v_pub_fb and cardinality(v_redes) = 0 then
      v_erro := case
        when v_tem_sa is null and cardinality(v_redes) = 0 then 'social_accounts nao encontrado para essa marca'
        else 'nenhum canal ligado para este post (marca ou post desligou todos)' end;
    end if;

    if v_erro is null then
      select count(*) into v_qtd from posta_ai.post_assets pa where pa.post_id = v_post_id;
      if v_qtd = 0 then
        v_erro := 'post sem asset anexado';
      elsif v_qtd > 10 and v_formato <> 'story' then
        v_erro := format('carrossel aceita no maximo 10 itens (esse post tem %s)', v_qtd);
      end if;
    end if;

    if v_erro is not null then
      update posta_ai.posts set status = 'falhou', atualizado_em = now() where id = v_post_id;
      insert into posta_ai.publish_jobs (post_id, tentativa, status, erro)
      values (v_post_id, 1, 'falhou', v_erro);
      insert into posta_ai.post_events (post_id, de_status, para_status, autor)
      values (v_post_id, 'publicando', 'falhou', 'sistema');
      return;
    end if;

    v_lote := gen_random_uuid();
    if v_pub_ig then
      insert into posta_ai.publish_jobs (post_id, tentativa, status, canal, lote)
      values (v_post_id, 1, 'pendente', 'instagram', v_lote);
    end if;
    if v_pub_fb then
      insert into posta_ai.publish_jobs (post_id, tentativa, status, canal, lote)
      values (v_post_id, 1, 'pendente', 'facebook', v_lote);
    end if;
    foreach v_rede in array v_redes loop
      insert into posta_ai.publish_jobs (post_id, tentativa, status, canal, lote)
      values (v_post_id, 1, 'pendente', v_rede, v_lote);
    end loop;

    -- ordem de saída: instagram, facebook, tiktok, youtube
    update posta_ai.publish_jobs j
       set status = 'em_andamento', iniciado_em = now()
     where j.id = (
       select j2.id from posta_ai.publish_jobs j2
       where j2.post_id = v_post_id and j2.lote = v_lote
       order by array_position(array['instagram','facebook','tiktok','youtube'], j2.canal)
       limit 1
     )
    returning j.id, j.canal into v_job_id, v_canal;
  end if;

  -- TikTok / YouTube: a Edge Function completa com rpc_dados_job_rede(job_id)
  if v_canal in ('tiktok', 'youtube') then
    return query select v_job_id, v_post_id, v_canal,
      null::text, null::text, null::text, 'VIDEO'::text, '[]'::jsonb;
    return;
  end if;

  -- Payload Meta (inalterado)
  select decrypted_secret into v_token
  from vault.decrypted_secrets
  where id = v_secret;

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

  if v_formato = 'story' and jsonb_array_length(v_assets) > 1 then
    v_assets := jsonb_build_array(v_assets -> 0);
  end if;

  v_qtd := jsonb_array_length(v_assets);
  v_tipo_primeiro := v_assets -> 0 ->> 'tipo';

  select pc.corpo into v_corpo
  from posta_ai.post_captions pc
  where pc.post_id = v_post_id
  order by pc.versao desc
  limit 1;

  if v_canal = 'facebook' then
    select pc.corpo_fb into v_corpo_fb
    from posta_ai.post_captions pc
    where pc.post_id = v_post_id and pc.corpo_fb is not null
    order by pc.versao desc
    limit 1;
    v_corpo := coalesce(v_corpo_fb, v_corpo);
  end if;

  select cb.conteudo into v_assinatura
  from posta_ai.caption_blocks cb
  where cb.brand_id = v_brand_id
    and cb.tipo = 'assinatura_padrao'
    and cb.ativo = true
  limit 1;

  v_legenda := coalesce(v_corpo, '');
  if v_assinatura is not null and v_assinatura <> '' then
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

  return query select
    v_job_id, v_post_id, v_canal,
    case when v_canal = 'facebook' then v_page else v_ig end,
    v_token, v_legenda, v_media_type, v_assets;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Payload de um job de tiktok/youtube (service_role)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.rpc_dados_job_rede(p_job_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'vault', 'public'
as $function$
declare
  v_job posta_ai.publish_jobs;
  v_post posta_ai.posts;
  v_conta posta_ai.contas_rede;
  v_cap posta_ai.post_captions;
  v_assinatura text;
  v_corpo text;
  v_titulo text;
  v_descricao text;
  v_video text;
begin
  select * into v_job from posta_ai.publish_jobs where id = p_job_id;
  if v_job.id is null or v_job.canal not in ('tiktok', 'youtube') then
    raise exception 'job % nao e de tiktok/youtube', p_job_id;
  end if;

  select * into v_post from posta_ai.posts where id = v_job.post_id;
  select * into v_conta from posta_ai.contas_rede
   where brand_id = v_post.brand_id and rede = v_job.canal and ativo;
  if v_conta.id is null then
    raise exception 'marca sem conta % ativa', v_job.canal;
  end if;

  select * into v_cap from posta_ai.post_captions
   where post_id = v_post.id order by versao desc limit 1;

  select cb.conteudo into v_assinatura
  from posta_ai.caption_blocks cb
  where cb.brand_id = v_post.brand_id and cb.tipo = 'assinatura_padrao' and cb.ativo
  limit 1;

  v_corpo := coalesce(v_cap.corpo, '');
  if coalesce(v_assinatura, '') <> '' then
    v_corpo := v_corpo || E'\n\n' || v_assinatura;
  end if;

  -- D5: título do Shorts = 1ª frase (até 100), descrição = legenda do IG
  v_titulo := coalesce(nullif(btrim(v_cap.titulo_youtube), ''),
                       left(btrim(split_part(split_part(coalesce(v_cap.corpo, ''), E'\n', 1), '. ', 1)), 100));
  if coalesce(v_titulo, '') = '' then v_titulo := coalesce(v_post.titulo_interno, 'Vídeo'); end if;
  v_descricao := coalesce(nullif(btrim(v_cap.descricao_youtube), ''), v_corpo);

  select pa.url into v_video
  from posta_ai.post_assets pa
  where pa.post_id = v_post.id and pa.tipo = 'video'
  order by pa.ordem limit 1;

  return jsonb_build_object(
    'job_id', v_job.id,
    'post_id', v_post.id,
    'canal', v_job.canal,
    'etapa', v_job.etapa,
    'externo_id', v_job.externo_id,
    'confirmacoes', v_job.confirmacoes,
    'conta_rede_id', v_conta.id,
    'conta_externa_id', v_conta.conta_externa_id,
    'modo', v_conta.modo,
    'access_token', (select decrypted_secret from vault.decrypted_secrets where id = v_conta.token_secret_id),
    'refresh_token', (select decrypted_secret from vault.decrypted_secrets where id = v_conta.refresh_secret_id),
    'expira_em', v_conta.expira_em,
    'video_url', v_video,
    'legenda', case when v_job.canal = 'tiktok'
                    then left(coalesce(nullif(btrim(v_cap.corpo_tiktok), ''), v_corpo), 2200)
                    else null end,
    'titulo', case when v_job.canal = 'youtube' then v_titulo else null end,
    'descricao', case when v_job.canal = 'youtube' then left(v_descricao, 5000) else null end,
    'opcoes_tiktok', v_post.opcoes_tiktok
  );
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Resultado de um job de tiktok/youtube (service_role)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.rpc_marcar_resultado_job_rede(
  p_job_id uuid, p_sucesso boolean,
  p_externo_id text default null, p_externo_url text default null,
  p_visibilidade text default null, p_erro text default null)
 returns text
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'public'
as $function$
declare
  v_post_id uuid;
  v_lote uuid;
begin
  update posta_ai.publish_jobs
     set status       = case when p_sucesso then 'publicado' else 'falhou' end,
         externo_id   = coalesce(p_externo_id, externo_id),
         externo_url  = coalesce(p_externo_url, externo_url),
         visibilidade = coalesce(p_visibilidade, visibilidade),
         etapa        = null,
         erro         = case when p_sucesso then erro else p_erro end,
         publicado_em = case when p_sucesso then now() else publicado_em end
   where id = p_job_id
     and status = 'em_andamento'
     and canal in ('tiktok', 'youtube')
  returning post_id, lote into v_post_id, v_lote;

  if v_post_id is null then
    return 'ignorado';
  end if;

  return posta_ai.finalizar_publicacao(v_post_id, v_lote);
end;
$function$;

-- Fase 1 terminou (arquivo enviado), falta a rede confirmar: devolve à fila.
-- Depois de 12 tentativas (~2 h com cron de 10 min) desiste.
create or replace function public.rpc_job_aguardar_confirmacao(p_job_id uuid, p_externo_id text)
 returns text
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'public'
as $function$
declare
  v_job posta_ai.publish_jobs;
begin
  update posta_ai.publish_jobs
     set status = 'pendente',
         etapa = 'confirmar',
         externo_id = coalesce(p_externo_id, externo_id),
         confirmacoes = confirmacoes + 1
   where id = p_job_id
     and status = 'em_andamento'
     and canal in ('tiktok', 'youtube')
  returning * into v_job;

  if v_job.id is null then
    return 'ignorado';
  end if;

  if v_job.confirmacoes > 12 then
    update posta_ai.publish_jobs
       set status = 'falhou',
           erro = format('a rede nao confirmou o envio %s depois de %s tentativas. Conferir no app antes de reagendar.',
                         v_job.externo_id, v_job.confirmacoes)
     where id = p_job_id;
    return posta_ai.finalizar_publicacao(v_job.post_id, v_job.lote);
  end if;

  return 'aguardando_confirmacao';
end;
$function$;

-- Renovação de token feita pela Edge Function (service_role).
create or replace function public.rpc_atualizar_tokens_rede(
  p_conta_rede_id uuid, p_access_token text, p_refresh_token text,
  p_expira_em timestamptz, p_refresh_expira_em timestamptz default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'vault', 'public'
as $function$
declare
  v_conta posta_ai.contas_rede;
begin
  select * into v_conta from posta_ai.contas_rede where id = p_conta_rede_id for update;
  if v_conta.id is null then raise exception 'conta nao encontrada'; end if;

  perform vault.update_secret(v_conta.token_secret_id, p_access_token);
  if p_refresh_token is not null then
    if v_conta.refresh_secret_id is null then
      update posta_ai.contas_rede
         set refresh_secret_id = vault.create_secret(p_refresh_token,
               format('%s_refresh_%s', v_conta.rede, v_conta.id))
       where id = v_conta.id;
    else
      perform vault.update_secret(v_conta.refresh_secret_id, p_refresh_token);
    end if;
  end if;

  update posta_ai.contas_rede
     set expira_em = p_expira_em,
         refresh_expira_em = coalesce(p_refresh_expira_em, refresh_expira_em),
         atualizado_em = now()
   where id = v_conta.id;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Conexão por OAuth
-- ─────────────────────────────────────────────────────────────────────────────
-- Painel (admin): gera o state de uso único. O front monta a URL de autorização.
create or replace function public.posta_ai_admin_iniciar_conexao(p_brand_id uuid, p_rede text)
 returns text
 language plpgsql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
declare
  v_state text;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  if p_rede not in ('tiktok', 'youtube') then raise exception 'rede invalida'; end if;
  if not exists (select 1 from posta_ai.brands where id = p_brand_id) then
    raise exception 'marca nao encontrada';
  end if;

  delete from posta_ai.oauth_estados where expira_em < now() - interval '1 day';

  v_state := encode(extensions.gen_random_bytes(24), 'hex');
  insert into posta_ai.oauth_estados (state, brand_id, rede) values (v_state, p_brand_id, p_rede);
  return v_state;
end;
$function$;

-- Edge Function oauth-redes (service_role): consome o state e grava a conta.
create or replace function public.rpc_concluir_conexao_rede(
  p_state text, p_rede text, p_conta_externa_id text, p_apelido text, p_avatar_url text,
  p_access_token text, p_refresh_token text, p_expira_em timestamptz,
  p_refresh_expira_em timestamptz, p_escopos text[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'posta_ai', 'vault', 'public'
as $function$
declare
  v_est posta_ai.oauth_estados;
  v_conta posta_ai.contas_rede;
  v_access uuid;
  v_refresh uuid;
begin
  update posta_ai.oauth_estados
     set usado_em = now()
   where state = p_state and usado_em is null and expira_em > now() and rede = p_rede
  returning * into v_est;
  if v_est.state is null then
    raise exception 'state invalido, expirado ou ja usado';
  end if;

  select * into v_conta from posta_ai.contas_rede
   where brand_id = v_est.brand_id and rede = p_rede for update;

  if v_conta.id is null then
    v_access := vault.create_secret(p_access_token, format('%s_access_%s', p_rede, gen_random_uuid()));
    if p_refresh_token is not null then
      v_refresh := vault.create_secret(p_refresh_token, format('%s_refresh_%s', p_rede, gen_random_uuid()));
    end if;
    insert into posta_ai.contas_rede (brand_id, rede, conta_externa_id, apelido, avatar_url,
      token_secret_id, refresh_secret_id, expira_em, refresh_expira_em, escopos,
      publicar_por_padrao)
    values (v_est.brand_id, p_rede, p_conta_externa_id, p_apelido, p_avatar_url,
      v_access, v_refresh, p_expira_em, p_refresh_expira_em, coalesce(p_escopos, '{}'),
      -- D6: YouTube só entra no padrão depois da auditoria (vídeo não auditado fica travado privado)
      p_rede = 'tiktok')
    returning * into v_conta;
  else
    perform vault.update_secret(v_conta.token_secret_id, p_access_token);
    if p_refresh_token is not null then
      if v_conta.refresh_secret_id is null then
        v_refresh := vault.create_secret(p_refresh_token, format('%s_refresh_%s', p_rede, gen_random_uuid()));
      else
        perform vault.update_secret(v_conta.refresh_secret_id, p_refresh_token);
        v_refresh := v_conta.refresh_secret_id;
      end if;
    end if;
    update posta_ai.contas_rede
       set conta_externa_id = p_conta_externa_id,
           apelido = p_apelido,
           avatar_url = p_avatar_url,
           refresh_secret_id = coalesce(v_refresh, refresh_secret_id),
           expira_em = p_expira_em,
           refresh_expira_em = p_refresh_expira_em,
           escopos = coalesce(p_escopos, escopos),
           ativo = true,
           conectado_em = now(),
           atualizado_em = now()
     where id = v_conta.id
    returning * into v_conta;
  end if;

  return jsonb_build_object('brand_id', v_conta.brand_id, 'rede', v_conta.rede, 'apelido', v_conta.apelido);
end;
$function$;

-- Painel (admin): lista as contas conectadas de uma marca, sem token.
create or replace function public.posta_ai_admin_contas_rede(p_brand_id uuid)
 returns table(id uuid, rede text, apelido text, avatar_url text, modo text,
               publicar_por_padrao boolean, ativo boolean, expira_em timestamptz,
               refresh_expira_em timestamptz, conectado_em timestamptz)
 language sql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
  select cr.id, cr.rede, cr.apelido, cr.avatar_url, cr.modo, cr.publicar_por_padrao,
         cr.ativo, cr.expira_em, cr.refresh_expira_em, cr.conectado_em
  from posta_ai.contas_rede cr
  where cr.brand_id = p_brand_id and public.posta_ai_is_admin()
  order by cr.rede;
$function$;

-- Painel (admin): liga/desliga padrão e modo. Desconectar = ativo false.
create or replace function public.posta_ai_admin_ajustar_conta_rede(
  p_conta_rede_id uuid, p_publicar_por_padrao boolean, p_modo text, p_ativo boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  update posta_ai.contas_rede
     set publicar_por_padrao = coalesce(p_publicar_por_padrao, publicar_por_padrao),
         modo = coalesce(p_modo, modo),
         ativo = coalesce(p_ativo, ativo),
         atualizado_em = now()
   where id = p_conta_rede_id;
  if not found then raise exception 'conta nao encontrada'; end if;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Grants: service_role-only para as RPCs da fila; authenticated só nas de admin
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public.rpc_proximo_job_publicacao() from public, anon, authenticated;
grant execute on function public.rpc_proximo_job_publicacao() to service_role;

revoke all on function public.rpc_dados_job_rede(uuid) from public, anon, authenticated;
grant execute on function public.rpc_dados_job_rede(uuid) to service_role;

revoke all on function public.rpc_marcar_resultado_job_rede(uuid, boolean, text, text, text, text) from public, anon, authenticated;
grant execute on function public.rpc_marcar_resultado_job_rede(uuid, boolean, text, text, text, text) to service_role;

revoke all on function public.rpc_job_aguardar_confirmacao(uuid, text) from public, anon, authenticated;
grant execute on function public.rpc_job_aguardar_confirmacao(uuid, text) to service_role;

revoke all on function public.rpc_atualizar_tokens_rede(uuid, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.rpc_atualizar_tokens_rede(uuid, text, text, timestamptz, timestamptz) to service_role;

revoke all on function public.rpc_concluir_conexao_rede(text, text, text, text, text, text, text, timestamptz, timestamptz, text[]) from public, anon, authenticated;
grant execute on function public.rpc_concluir_conexao_rede(text, text, text, text, text, text, text, timestamptz, timestamptz, text[]) to service_role;

revoke all on function public.posta_ai_admin_iniciar_conexao(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_iniciar_conexao(uuid, text) to authenticated;

revoke all on function public.posta_ai_admin_contas_rede(uuid) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_contas_rede(uuid) to authenticated;

revoke all on function public.posta_ai_admin_ajustar_conta_rede(uuid, boolean, text, boolean) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_ajustar_conta_rede(uuid, boolean, text, boolean) to authenticated;

commit;
