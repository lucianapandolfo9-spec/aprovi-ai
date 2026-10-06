-- =====================================================================
-- aprovi.ai — FASE "CERTO AGRO NO APROVI.AI" (06/10/2026)
-- =====================================================================
--
-- Desenho fechado no /grill-me de 06/10/2026 com a Luciana:
--   Obvision/Luh Panda/Dev/Sistemas/aprovi.ai/
--   "Certo Agro no aprovi.ai — Desenho (grill 06-10-2026).md"
--
-- O QUE ENTRA (itens 1, 2, 3, 4-backend e 5 do desenho; o item 6, cadastro,
-- fica em supabase/cadastros/ porque é dado de produção, não schema):
--
--   1. Página do Facebook como canal: `publish_jobs` passa a ter UMA LINHA
--      POR CANAL (`canal` = instagram | facebook), agrupadas por `lote`
--      (uma rodada de publicação de um post). Colunas próprias do FB.
--   2. Cross-post: `social_accounts.publicar_instagram / publicar_facebook`
--      decidem os canais da marca; `post_captions.corpo_fb` é a legenda
--      opcional do Facebook (NULL = usa a do Instagram).
--   3. Vários stories por dia, com horário por marca no fuso da marca:
--      tabela `story_horarios`. `enfileirar_story_diario` deixa de ter o
--      meio-dia de Los Angeles chumbado e passa a ler os horários de rodízio
--      da marca em `brands.timezone`. A Gigi ganha a linha 12:00 todo dia,
--      que reproduz EXATAMENTE o comportamento antigo (ver bloco 6).
--      Horário de "repost": o story companheiro de um feed vai pro próximo
--      horário de repost livre da marca; marca sem horário de repost segue
--      com o D+1 de sempre (Gigi e Luh Panda não mudam).
--   4. Automação com molde aprovado 1x: tabela `automacoes` + RPC
--      `posta_ai_automacao_criar_post`, que o n8n chama pra criar o story da
--      cotação já `agendado`. Autenticada por segredo próprio da automação
--      (header x-automacao-secret, só o SHA-256 fica no banco), idempotente
--      por `chave_externa`.
--   5. Limpeza de Storage: mídia de post publicado há 30+ dias. As RPCs
--      listam e marcam; quem apaga os bytes é a Edge Function
--      `limpar-midia-publicada` (Storage API, única forma de liberar espaço).
--      Mídia de marca com rodízio de story ativo NÃO entra (Gigi — decisão
--      dela em 06/10: os publicados alimentam o rodízio).
--
-- COMPATIBILIDADE — esta migration é ADITIVA:
--   * rpc_proximo_post_agendado e rpc_marcar_resultado_publicacao NÃO são
--     tocadas. A Edge Function v20 continua funcionando igual depois que
--     esta migration entrar. Só a v21 usa as RPCs novas.
--   * Nenhuma função existente é recriada com DROP: só CREATE OR REPLACE,
--     que PRESERVA grants (lição de 01/10/2026). Funções novas recebem o
--     bloco de grants explícito no fim.
--   * Gigi e Luh Panda continuam só Instagram (publicar_facebook = false).
--
-- 🔴 ORDEM EM PRODUÇÃO: 1) esta migration · 2) deploy da v21 de
--    publicar-posts-agendados · 3) cadastro do Certo Agro. Cadastrar a marca
--    ANTES da v21 faria o post do Certo Agro sair só no Instagram (a v20
--    ignora o canal facebook).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. COLUNAS NOVAS (todas com default → nenhuma linha existente muda)
-- ---------------------------------------------------------------------

alter table posta_ai.social_accounts
  add column if not exists publicar_instagram boolean not null default true,
  add column if not exists publicar_facebook  boolean not null default false;

comment on column posta_ai.social_accounts.publicar_facebook is
  'Publica também na Página (page_id). false = só Instagram, que é o comportamento '
  'de antes de 06/10/2026. Ligado só no Certo Agro.';

-- Legenda opcional do Facebook. NULL = usa `corpo`. A RPC pega a versão
-- mais recente que tenha corpo_fb preenchido — editar a legenda do IG depois
-- (nova versão sem corpo_fb) não apaga a do FB.
alter table posta_ai.post_captions
  add column if not exists corpo_fb text;

-- Marca que o arquivo foi apagado do Storage pela limpeza. A URL fica
-- (histórico), mas ninguém mais a usa como fonte (rodízio ignora).
alter table posta_ai.post_assets
  add column if not exists midia_removida_em timestamptz;

alter table posta_ai.publish_jobs
  add column if not exists canal        text not null default 'instagram',
  add column if not exists lote         uuid,
  add column if not exists iniciado_em  timestamptz,
  add column if not exists fb_objeto_id text,
  add column if not exists fb_post_id   text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'publish_jobs_canal_check') then
    alter table posta_ai.publish_jobs
      add constraint publish_jobs_canal_check check (canal in ('instagram', 'facebook'));
  end if;
end $$;

comment on column posta_ai.publish_jobs.lote is
  'Rodada de publicação de um post: 1 linha por canal. NULL = job antigo '
  '(antes de 06/10/2026), sempre de um canal só, o Instagram.';
comment on column posta_ai.publish_jobs.iniciado_em is
  'Quando a Edge Function pegou o job. O 2º canal de um lote nasce `pendente` '
  'e só começa no cron seguinte: o ceifador mede a partir daqui, não de criado_em.';

-- Um canal por lote, nunca dois: trava de banco contra publicação dupla.
create unique index if not exists publish_jobs_lote_canal_uniq
  on posta_ai.publish_jobs (post_id, lote, canal) where lote is not null;

create index if not exists publish_jobs_pendente_idx
  on posta_ai.publish_jobs (criado_em) where status = 'pendente';


-- ---------------------------------------------------------------------
-- 2. TABELAS NOVAS
-- ---------------------------------------------------------------------

-- Horários de story por marca, no fuso da marca (brands.timezone).
--   rodizio → enfileirar_story_diario preenche com um reel/feed aprovado
--             (o dia recebe no máximo tantos stories quantos horários de
--             rodízio ativos ele tiver — companheiro e cotação contam)
--   repost  → o story companheiro de um feed/reel publicado vai pro próximo
--             horário de repost livre
create table if not exists posta_ai.story_horarios (
  id uuid not null default gen_random_uuid(),
  brand_id uuid not null,
  tipo text not null,
  hora time not null,
  -- ISO: 1 = segunda … 7 = domingo
  dias_semana smallint[] not null default '{1,2,3,4,5,6,7}',
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  constraint story_horarios_pkey primary key (id),
  constraint story_horarios_brand_id_fkey foreign key (brand_id)
    references posta_ai.brands(id) on delete cascade,
  constraint story_horarios_tipo_check check (tipo in ('rodizio', 'repost')),
  constraint story_horarios_dias_check check (
    cardinality(dias_semana) between 1 and 7
    and dias_semana <@ '{1,2,3,4,5,6,7}'::smallint[]
  ),
  constraint story_horarios_uniq unique (brand_id, tipo, hora)
);

-- Automação externa que cria post sozinha (hoje: n8n do card de cotação).
-- `molde_aprovado = true` é a decisão 5 do grill: molde aprovado 1x, o post
-- nasce `agendado`. false → nasce `em_aprovacao` e passa pelo link secreto.
create table if not exists posta_ai.automacoes (
  id uuid not null default gen_random_uuid(),
  brand_id uuid not null,
  nome text not null,
  descricao text,
  -- SHA-256 (hex) do segredo. O valor cru nunca entra no banco.
  segredo_sha256 text not null,
  formatos text[] not null,
  molde_aprovado boolean not null default false,
  -- de onde vem o molde aprovado (ex.: commit do arquivo). Auditoria.
  molde_ref text,
  -- toda URL de mídia tem que começar com isto (pasta da marca no bucket)
  url_base_midia text not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  constraint automacoes_pkey primary key (id),
  constraint automacoes_nome_key unique (nome),
  constraint automacoes_brand_id_fkey foreign key (brand_id)
    references posta_ai.brands(id) on delete cascade,
  constraint automacoes_sha_check check (segredo_sha256 ~ '^[0-9a-f]{64}$'),
  constraint automacoes_formatos_check check (
    cardinality(formatos) >= 1
    and formatos <@ array['reel', 'feed', 'story', 'carrossel']
  )
);

alter table posta_ai.posts
  add column if not exists automacao_id uuid,
  add column if not exists chave_externa text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'posts_automacao_id_fkey') then
    alter table posta_ai.posts
      add constraint posts_automacao_id_fkey foreign key (automacao_id)
      references posta_ai.automacoes(id) on delete set null;
  end if;
end $$;

-- Idempotência da automação: a mesma chave nunca vira dois posts.
create unique index if not exists posts_automacao_chave_uniq
  on posta_ai.posts (automacao_id, chave_externa) where automacao_id is not null;

-- Mesmo desenho das outras 10: RLS ligado, ZERO policies, acesso só por
-- função SECURITY DEFINER. Policy aqui é regressão.
alter table posta_ai.story_horarios enable row level security;
alter table posta_ai.automacoes     enable row level security;


-- ---------------------------------------------------------------------
-- 3. HORÁRIOS: próximo horário livre de uma marca
-- ---------------------------------------------------------------------
-- "Livre" = nenhum story não-falho da marca agendado exatamente nesse
-- instante. Procura até p_max_dias à frente.
create or replace function posta_ai.proximo_horario_livre(
  p_brand_id uuid,
  p_tipo text,
  p_depois timestamptz,
  p_max_dias integer default 14
)
returns timestamptz
language sql
stable
security definer
set search_path to 'posta_ai', 'public'
as $function$
  select t.inst
  from posta_ai.brands b
  join posta_ai.story_horarios h
    on h.brand_id = b.id and h.tipo = p_tipo and h.ativo
  cross join generate_series(0, p_max_dias) as g(d)
  cross join lateral (
    select ((p_depois at time zone b.timezone)::date + g.d) as dia
  ) dd
  cross join lateral (
    select ((dd.dia + h.hora) at time zone b.timezone) as inst
  ) t
  where b.id = p_brand_id
    and extract(isodow from dd.dia)::smallint = any (h.dias_semana)
    and t.inst > p_depois
    and not exists (
      select 1 from posta_ai.posts s
      where s.brand_id = b.id
        and s.formato = 'story'
        and s.status <> 'falhou'
        and s.agendado_para = t.inst
    )
  order by t.inst
  limit 1
$function$;


-- ---------------------------------------------------------------------
-- 4. RODÍZIO DIÁRIO — sem Los Angeles chumbado
-- ---------------------------------------------------------------------
-- Mesma assinatura (CREATE OR REPLACE preserva o grant de service_role).
--
-- Equivalência com a versão anterior, pra uma marca com UM horário de
-- rodízio (a Gigi, 12:00 em America/Los_Angeles):
--   antes: alvo = próximo 12:00 LA que ainda não passou; se o dia-alvo já
--          tem QUALQUER story não-falho, não cria nada.
--   agora: dia-alvo = dia da próxima ocorrência de rodízio que ainda não
--          passou; o dia recebe stories de rodízio até o número de horários
--          de rodízio do dia (1) — contando os que já existem (companheiro
--          incluso). Com 1 horário, é a mesma regra.
-- Fonte do rodízio: igual a antes + ignora mídia já apagada pela limpeza.
create or replace function posta_ai.enfileirar_story_diario(p_brand_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'posta_ai', 'public'
as $function$
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

  -- Dia-alvo: o da próxima ocorrência de rodízio (hoje ou amanhã, no fuso
  -- da marca) que ainda não passou. Fuso nomeado, então horário de verão
  -- não desloca a postagem.
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
    return null;  -- marca sem horário de rodízio: nada a fazer
  end if;

  select count(*) into v_qtd_horarios
  from posta_ai.story_horarios h
  where h.brand_id = p_brand_id and h.tipo = 'rodizio' and h.ativo
    and extract(isodow from v_dia_alvo)::smallint = any (h.dias_semana);

  -- Quantos stories o dia já tem (companheiro, cotação, rodízio de antes).
  -- Cobre também o cron rodando duas vezes no mesmo dia: idempotente.
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

    -- Escolhe o vídeo elegível que está há mais tempo sem ir pra story.
    -- Elegível = post de feed/reel já aprovado (aprovado/agendado/publicado)
    -- cuja mídia ainda existe no Storage.
    select p.id, p.titulo_interno, a.tipo, a.url, a.duracao_seg
    into v_fonte
    from posta_ai.posts p
    join posta_ai.post_assets a
      on a.post_id = p.id and a.ordem = 0
    where p.brand_id = p_brand_id
      and p.formato in ('reel', 'feed')
      and p.status in ('aprovado', 'agendado', 'publicado')
      and a.tipo = 'video'
      and a.midia_removida_em is null
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

    -- Instagram não exibe legenda em story (a Edge Function omite o campo),
    -- mas copiar mantém o card do painel legível.
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


-- ---------------------------------------------------------------------
-- 5. PUBLICAÇÃO POR CANAL
-- ---------------------------------------------------------------------

-- Story companheiro (extraído de rpc_marcar_resultado_publicacao, mesma
-- regra: só reel/feed, só uma vez por post de origem). Única diferença:
-- se a marca tem horário de REPOST, o story vai pro próximo livre; se não
-- tem, D+1 no mesmo horário, como sempre foi.
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

-- Fecha o post quando todos os canais do lote terminaram.
--   algum canal publicou → post `publicado` (+ story companheiro)
--   nenhum publicou      → post `falhou`
-- Canal que falhou NUNCA é retentado sozinho (repetir o que deu certo
-- duplicaria o post no outro canal). Fica registrado no job dele.
create or replace function posta_ai.finalizar_publicacao(p_post_id uuid, p_lote uuid)
returns text
language plpgsql
security definer
set search_path to 'posta_ai', 'public'
as $function$
declare
  v_algum boolean;
  v_novo text;
begin
  if exists (
    select 1 from posta_ai.publish_jobs
    where post_id = p_post_id and lote = p_lote
      and status in ('pendente', 'em_andamento')
  ) then
    return 'aguardando';
  end if;

  select coalesce(bool_or(status = 'publicado'), false) into v_algum
  from posta_ai.publish_jobs
  where post_id = p_post_id and lote = p_lote;

  v_novo := case when v_algum then 'publicado' else 'falhou' end;

  update posta_ai.posts
     set status = v_novo, atualizado_em = now()
   where id = p_post_id and status = 'publicando';

  if not found then
    return 'ignorado';
  end if;

  insert into posta_ai.post_events (post_id, de_status, para_status, autor)
  values (p_post_id, 'publicando', v_novo, 'sistema');

  if v_algum then
    perform posta_ai.gerar_story_companheiro(p_post_id);
  end if;

  return v_novo;
end;
$function$;

-- Fila da Edge Function v21. Devolve UM job (um canal de um post):
--   1º) job `pendente` de um lote já aberto (o 2º canal de um post que já
--       está `publicando`) — mais antigo primeiro, Instagram antes;
--   2º) senão, o próximo post `agendado` vencido: vira `publicando`, nasce
--       um lote com um job por canal ligado na marca, e o 1º é devolvido.
-- Um job por execução: o 2º canal sai no cron seguinte (+10 min). É o que
-- mantém cada execução longe do teto de ~150s da org free.
-- 🔴 service_role-only: decripta o token da Meta e devolve na coluna token.
create or replace function public.rpc_proximo_job_publicacao()
returns table(
  job_id uuid, post_id uuid, canal text, conta_id text, token text,
  caption text, media_type text, assets jsonb
)
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
begin
  -- 1) 2º canal de um lote em andamento
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
    returning p.id, p.brand_id, p.formato
    into v_post_id, v_brand_id, v_formato;

    if v_post_id is null then
      return;
    end if;

    select sa.ig_user_id, sa.page_id, sa.token_secret_id,
           sa.publicar_instagram, sa.publicar_facebook
    into v_ig, v_page, v_secret, v_pub_ig, v_pub_fb
    from posta_ai.social_accounts sa
    where sa.brand_id = v_brand_id
    limit 1;

    if not found then
      v_erro := 'social_accounts nao encontrado para essa marca';
    elsif not coalesce(v_pub_ig, false) and not coalesce(v_pub_fb, false) then
      v_erro := 'nenhum canal ligado em social_accounts (publicar_instagram e publicar_facebook = false)';
    elsif v_pub_ig and v_ig is null then
      v_erro := 'publicar_instagram ligado, mas a marca nao tem ig_user_id';
    elsif v_pub_fb and v_page is null then
      v_erro := 'publicar_facebook ligado, mas a marca nao tem page_id';
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

    update posta_ai.publish_jobs j
       set status = 'em_andamento', iniciado_em = now()
     where j.id = (
       select j2.id from posta_ai.publish_jobs j2
       where j2.post_id = v_post_id and j2.lote = v_lote
       order by (j2.canal <> 'instagram') asc
       limit 1
     )
    returning j.id, j.canal into v_job_id, v_canal;
  end if;

  -- Payload comum aos dois caminhos
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

  -- story nunca é carrossel: usa só o primeiro asset
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

-- Grava o resultado de UM job e fecha o post se o lote acabou.
-- Devolve: 'aguardando' (falta canal) | 'publicado' | 'falhou' | 'ignorado'.
-- 🔴 service_role-only.
create or replace function public.rpc_marcar_resultado_job(
  p_job_id uuid,
  p_sucesso boolean,
  p_ig_creation_id text default null,
  p_ig_media_id text default null,
  p_fb_objeto_id text default null,
  p_fb_post_id text default null,
  p_erro text default null
)
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
     set status         = case when p_sucesso then 'publicado' else 'falhou' end,
         ig_creation_id = coalesce(p_ig_creation_id, ig_creation_id),
         ig_media_id    = coalesce(p_ig_media_id, ig_media_id),
         fb_objeto_id   = coalesce(p_fb_objeto_id, fb_objeto_id),
         fb_post_id     = coalesce(p_fb_post_id, fb_post_id),
         erro           = case when p_sucesso then erro else p_erro end,
         publicado_em   = case when p_sucesso then now() else publicado_em end
   where id = p_job_id
     and status = 'em_andamento'
  returning post_id, lote into v_post_id, v_lote;

  if v_post_id is null then
    return 'ignorado';  -- já terminado (ex.: ceifado). Nunca reabre.
  end if;

  if v_lote is null then
    -- job sem lote não nasce por este caminho; defensivo
    update posta_ai.posts
       set status = case when p_sucesso then 'publicado' else 'falhou' end,
           atualizado_em = now()
     where id = v_post_id and status = 'publicando';
    return case when p_sucesso then 'publicado' else 'falhou' end;
  end if;

  return posta_ai.finalizar_publicacao(v_post_id, v_lote);
end;
$function$;


-- ---------------------------------------------------------------------
-- 6. CEIFADOR — mede de iniciado_em e fecha por lote
-- ---------------------------------------------------------------------
-- Mesma regra de 05/10/2026 (job em_andamento há mais de 20 min → falhou,
-- NUNCA reagenda). Mudanças: (a) mede a partir de `iniciado_em` — o 2º
-- canal nasce `pendente` antes de começar; (b) job com lote fecha o post
-- por `finalizar_publicacao` (se o outro canal publicou, o post é
-- `publicado`; se ainda tem canal pendente, espera).
create or replace function posta_ai.ceifar_jobs_orfaos()
returns integer
language plpgsql
security definer
set search_path to 'posta_ai', 'public'
as $function$
declare
  v_job record;
  v_qtd integer := 0;
begin
  for v_job in
    select j.id, j.post_id, j.lote, j.canal,
           coalesce(j.iniciado_em, j.criado_em) as desde,
           j.ig_creation_id, j.fb_objeto_id
    from posta_ai.publish_jobs j
    where j.status = 'em_andamento'
      and coalesce(j.iniciado_em, j.criado_em) < now() - interval '20 minutes'
    for update skip locked
  loop
    update posta_ai.publish_jobs
       set status = 'falhou',
           erro   = format(
             'órfão: ficou em_andamento desde %s sem resultado (Edge Function provavelmente morta pelo teto de wall-clock). '
             'Marcado falhou pelo ceifador em %s. NÃO reagendado: conferir %s antes de reagendar%s.',
             to_char(v_job.desde at time zone 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
             to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
             case when v_job.canal = 'facebook' then 'a Página do Facebook'
                  else 'a lista de mídia do IG' end,
             case when v_job.ig_creation_id is not null
                    then format(' (container %s já tinha sido criado)', v_job.ig_creation_id)
                  when v_job.fb_objeto_id is not null
                    then format(' (objeto %s já tinha sido criado no Facebook)', v_job.fb_objeto_id)
                  else '' end
           )
     where id = v_job.id;

    if v_job.lote is null then
      -- job antigo (v20): comportamento de 05/10, intacto
      update posta_ai.posts
         set status = 'falhou', atualizado_em = now()
       where id = v_job.post_id
         and status = 'publicando';

      if found then
        insert into posta_ai.post_events (post_id, de_status, para_status, autor)
        values (v_job.post_id, 'publicando', 'falhou', 'sistema');
      end if;
    else
      perform posta_ai.finalizar_publicacao(v_job.post_id, v_job.lote);
    end if;

    v_qtd := v_qtd + 1;
  end loop;

  return v_qtd;
end;
$function$;


-- ---------------------------------------------------------------------
-- 7. AUTOMAÇÃO (n8n) — cria post pelo molde aprovado
-- ---------------------------------------------------------------------
-- Chamada por PostgREST: POST /rest/v1/rpc/posta_ai_automacao_criar_post
--   headers: apikey + Authorization (anon, pública) e
--            x-automacao-secret: <segredo cru da automação>
-- O segredo vai no HEADER, não no corpo, pra poder morar numa credencial
-- do n8n (que não injeta corpo). Lido de request.headers dentro do banco.
-- Erro de autorização é o mesmo pra automação inexistente e segredo errado
-- (não dá pra descobrir nome de automação por tentativa).
create or replace function public.posta_ai_automacao_criar_post(
  p_automacao text,
  p_chave text,
  p_titulo text,
  p_formato text,
  p_agendado_para timestamptz,
  p_assets jsonb,
  p_legenda text default null,
  p_legenda_fb text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'posta_ai', 'public', 'extensions'
as $function$
declare
  v_headers json;
  v_segredo text;
  v_auto posta_ai.automacoes%rowtype;
  v_post_id uuid;
  v_status text;
  v_item jsonb;
  v_ordem int := 0;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  v_segredo := coalesce(v_headers ->> 'x-automacao-secret', '');

  select * into v_auto
  from posta_ai.automacoes
  where nome = coalesce(p_automacao, '') and ativo;

  -- coalesce em tudo: comparação com NULL não é false (bug de 29/jul/2026)
  if not found
     or v_segredo = ''
     or encode(extensions.digest(v_segredo, 'sha256'), 'hex') <> coalesce(v_auto.segredo_sha256, '') then
    raise exception 'nao autorizado' using errcode = '42501';
  end if;

  if coalesce(p_formato, '') <> all (v_auto.formatos) then
    raise exception 'formato % nao permitido para a automacao %', p_formato, v_auto.nome
      using errcode = '22023';
  end if;

  if coalesce(trim(p_chave), '') = '' or length(p_chave) > 120 then
    raise exception 'chave_externa obrigatoria (ate 120 caracteres)' using errcode = '22023';
  end if;

  if p_agendado_para is null
     or p_agendado_para < now() - interval '5 minutes'
     or p_agendado_para > now() + interval '8 days' then
    raise exception 'agendado_para fora da janela (agora-5min .. agora+8 dias): %', p_agendado_para
      using errcode = '22023';
  end if;

  if jsonb_typeof(p_assets) is distinct from 'array'
     or jsonb_array_length(p_assets) < 1
     or jsonb_array_length(p_assets) > 10
     or (p_formato = 'story' and jsonb_array_length(p_assets) <> 1) then
    raise exception 'assets invalido (story = 1 item; demais = 1 a 10)' using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(p_assets) loop
    if coalesce(v_item ->> 'tipo', '') not in ('imagem', 'video')
       or left(coalesce(v_item ->> 'url', ''), length(v_auto.url_base_midia)) <> v_auto.url_base_midia then
      raise exception 'asset recusado: tipo imagem/video e url dentro de %', v_auto.url_base_midia
        using errcode = '22023';
    end if;
  end loop;

  -- idempotente: a mesma chave devolve o post que já existe
  select id into v_post_id
  from posta_ai.posts
  where automacao_id = v_auto.id and chave_externa = p_chave;

  if v_post_id is not null then
    return jsonb_build_object('post_id', v_post_id, 'criado', false);
  end if;

  v_status := case when v_auto.molde_aprovado then 'agendado' else 'em_aprovacao' end;

  begin
    insert into posta_ai.posts
      (brand_id, titulo_interno, formato, status, agendado_para, automacao_id, chave_externa)
    values
      (v_auto.brand_id, coalesce(nullif(trim(p_titulo), ''), v_auto.nome || ' ' || p_chave),
       p_formato, v_status, p_agendado_para, v_auto.id, p_chave)
    returning id into v_post_id;
  exception when unique_violation then
    -- corrida entre duas execuções da mesma chave
    select id into v_post_id
    from posta_ai.posts
    where automacao_id = v_auto.id and chave_externa = p_chave;
    return jsonb_build_object('post_id', v_post_id, 'criado', false);
  end;

  for v_item in select * from jsonb_array_elements(p_assets) loop
    insert into posta_ai.post_assets (post_id, ordem, tipo, url)
    values (v_post_id, v_ordem, v_item ->> 'tipo', v_item ->> 'url');
    v_ordem := v_ordem + 1;
  end loop;

  insert into posta_ai.post_captions (post_id, versao, corpo, corpo_fb, autor)
  values (v_post_id, 1, coalesce(p_legenda, ''), p_legenda_fb, 'auto');

  insert into posta_ai.post_events (post_id, de_status, para_status, autor)
  values (v_post_id, null, v_status, 'automacao:' || v_auto.nome);

  return jsonb_build_object('post_id', v_post_id, 'criado', true, 'status', v_status);
end;
$function$;


-- ---------------------------------------------------------------------
-- 8. LIMPEZA DE STORAGE — 30 dias depois de publicado
-- ---------------------------------------------------------------------
-- Uma URL entra na lista só se TODOS os posts que a usam estão `publicado`,
-- o último publicou há mais de p_dias, e nenhum deles é reel/feed de marca
-- com rodízio de story ativo (a mídia ainda alimenta o rodízio).
-- Piso de 30 dias dentro do banco: ninguém consegue pedir menos.
-- 🔴 service_role-only (as duas).
create or replace function public.rpc_midia_expirada(p_dias integer default 30)
returns table(
  url text, caminho text, bytes bigint, brand_id uuid,
  publicado_em timestamptz, existe_no_storage boolean
)
language plpgsql
stable
security definer
set search_path to 'posta_ai', 'storage', 'public'
as $function$
begin
  if p_dias is null or p_dias < 30 then
    raise exception 'p_dias minimo e 30 (recebido %)', p_dias using errcode = '22023';
  end if;

  return query
  with ref as (
    select a.url as u, p.brand_id as b, p.status as st,
           coalesce(
             (select max(j.publicado_em) from posta_ai.publish_jobs j
               where j.post_id = p.id and j.status = 'publicado'),
             p.atualizado_em
           ) as pub,
           (p.formato in ('reel', 'feed') and exists (
              select 1 from posta_ai.story_horarios h
              where h.brand_id = p.brand_id and h.tipo = 'rodizio' and h.ativo
           )) as protegido
    from posta_ai.post_assets a
    join posta_ai.posts p on p.id = a.post_id
    where a.midia_removida_em is null
      and position('/storage/v1/object/public/posta-ai-media/' in a.url) > 0
  ),
  por_url as (
    select r.u, min(r.b::text)::uuid as b,
           bool_and(r.st = 'publicado') as todos_publicados,
           bool_or(r.protegido) as protegido,
           max(r.pub) as ultimo
    from ref r
    group by r.u
  )
  select x.u,
         split_part(x.u, '/posta-ai-media/', 2),
         (o.metadata ->> 'size')::bigint,
         x.b,
         x.ultimo,
         (o.id is not null)
  from por_url x
  left join storage.objects o
    on o.bucket_id = 'posta-ai-media'
   and o.name = split_part(x.u, '/posta-ai-media/', 2)
  where x.todos_publicados
    and not x.protegido
    and x.ultimo < now() - make_interval(days => p_dias)
  order by x.ultimo asc;
end;
$function$;

create or replace function public.rpc_marcar_midia_removida(p_urls text[])
returns integer
language sql
security definer
set search_path to 'posta_ai', 'public'
as $function$
  with m as (
    update posta_ai.post_assets
       set midia_removida_em = now()
     where url = any (coalesce(p_urls, '{}'))
       and midia_removida_em is null
    returning 1
  )
  select count(*)::integer from m
$function$;


-- ---------------------------------------------------------------------
-- 9. GRANTS — explícitos em toda função nova (o default é PUBLIC)
-- ---------------------------------------------------------------------
revoke all on function posta_ai.proximo_horario_livre(uuid, text, timestamptz, integer) from public, anon, authenticated;
revoke all on function posta_ai.gerar_story_companheiro(uuid)            from public, anon, authenticated;
revoke all on function posta_ai.finalizar_publicacao(uuid, uuid)          from public, anon, authenticated;

revoke all on function public.rpc_proximo_job_publicacao() from public, anon, authenticated;
grant execute on function public.rpc_proximo_job_publicacao() to service_role;

revoke all on function public.rpc_marcar_resultado_job(uuid, boolean, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.rpc_marcar_resultado_job(uuid, boolean, text, text, text, text, text) to service_role;

revoke all on function public.rpc_midia_expirada(integer) from public, anon, authenticated;
grant execute on function public.rpc_midia_expirada(integer) to service_role;

revoke all on function public.rpc_marcar_midia_removida(text[]) from public, anon, authenticated;
grant execute on function public.rpc_marcar_midia_removida(text[]) to service_role;

-- A automação é chamada com a anon key; a autorização real é o segredo.
revoke all on function public.posta_ai_automacao_criar_post(text, text, text, text, timestamptz, jsonb, text, text) from public;
grant execute on function public.posta_ai_automacao_criar_post(text, text, text, text, timestamptz, jsonb, text, text) to anon, authenticated, service_role;

-- enfileirar_story_diario e ceifar_jobs_orfaos: CREATE OR REPLACE, grants
-- preservados. Reafirmados aqui mesmo assim (idempotente, e trava regressão).
revoke all on function posta_ai.enfileirar_story_diario(uuid) from public, anon, authenticated;
grant execute on function posta_ai.enfileirar_story_diario(uuid) to service_role;
revoke all on function posta_ai.ceifar_jobs_orfaos() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 10. GIGI: o horário que estava chumbado vira dado
-- ---------------------------------------------------------------------
-- Rodízio 12:00 todo dia no fuso da marca (America/Los_Angeles). Sem esta
-- linha o rodízio dela PARA, porque a função agora só lê story_horarios.
-- Condicional ao id de produção: numa réplica é no-op.
insert into posta_ai.story_horarios (brand_id, tipo, hora, dias_semana)
select b.id, 'rodizio', '12:00', '{1,2,3,4,5,6,7}'
from posta_ai.brands b
where b.id = '2c2c89a6-dfd4-4305-8231-4da572ae4161'
on conflict (brand_id, tipo, hora) do nothing;
