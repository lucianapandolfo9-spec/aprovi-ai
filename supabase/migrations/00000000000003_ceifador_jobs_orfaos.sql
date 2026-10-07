-- =====================================================================
-- aprovi.ai — CEIFADOR DE JOBS ÓRFÃOS (05/10/2026)
-- =====================================================================
--
-- POR QUE EXISTE: a Edge Function `publicar-posts-agendados` pode ser morta
-- pelo runtime (teto de wall-clock ~150s na org free) no meio do poll do
-- container da Meta. Morte pelo runtime não passa pelo `catch`, então nada é
-- gravado: o job fica `em_andamento` e o post `publicando` PRA SEMPRE, calado
-- (rpc_proximo_post_agendado só pega `agendado`). Aconteceu com o Organic2:
-- preso de 18/09 a 05/10/2026, ninguém viu.
--
-- O QUE FAZ: a cada 10 min, todo job `em_andamento` há mais de 20 min vira
-- `falhou` (job E post), com erro explicativo e linha em `post_events`.
-- 20 min é folga larga: uma execução legítima nunca passa de ~150s.
--
-- 🔴 NUNCA REAGENDA SOZINHO. Se a function morreu DEPOIS do `media_publish`
-- (publicou na Meta, mas não chegou a gravar), reagendar duplicaria o post no
-- perfil do cliente. Quem reagenda é humano, depois de conferir a lista de
-- mídia do IG. Por isso o post vira `falhou` (visível no painel), não volta
-- pra `agendado`.
--
-- Diferente do job 1 (00000000000002_cron_jobs.sql), este cron é LIGADO
-- aqui de propósito: ele não fala com a internet nem publica nada, só marca
-- falha. É inofensivo numa réplica.
-- =====================================================================

create or replace function posta_ai.ceifar_jobs_orfaos()
returns integer
language plpgsql
security definer
set search_path = posta_ai, public
as $$
declare
  v_job record;
  v_qtd integer := 0;
begin
  for v_job in
    select j.id, j.post_id, j.criado_em, j.ig_creation_id
    from posta_ai.publish_jobs j
    where j.status = 'em_andamento'
      and j.criado_em < now() - interval '20 minutes'
    for update skip locked
  loop
    update posta_ai.publish_jobs
       set status = 'falhou',
           erro   = format(
             'órfão: ficou em_andamento desde %s sem resultado (Edge Function provavelmente morta pelo teto de wall-clock). '
             'Marcado falhou pelo ceifador em %s. NÃO reagendado: conferir a lista de mídia do IG antes de reagendar%s.',
             to_char(v_job.criado_em at time zone 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
             to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
             case when v_job.ig_creation_id is not null
                  then format(' (container %s já tinha sido criado)', v_job.ig_creation_id)
                  else '' end
           )
     where id = v_job.id;

    update posta_ai.posts
       set status = 'falhou', atualizado_em = now()
     where id = v_job.post_id
       and status = 'publicando';

    if found then
      insert into posta_ai.post_events (post_id, de_status, para_status, autor)
      values (v_job.post_id, 'publicando', 'falhou', 'sistema');
    end if;

    v_qtd := v_qtd + 1;
  end loop;

  return v_qtd;
end;
$$;

revoke all on function posta_ai.ceifar_jobs_orfaos() from public, anon, authenticated;

-- 06/10/2026: numa réplica limpa o pg_cron não existe (a 00000000000002 deixa
-- o `create extension` comentado), e o `cron.schedule` abaixo quebrava a
-- aplicação inteira com `schema "cron" does not exist`. Achado no primeiro
-- `supabase start` limpo deste repo. Em produção é no-op (a extensão já existe).
create extension if not exists pg_cron with schema pg_catalog;

-- cron.schedule com o mesmo nome atualiza o job existente (idempotente).
select cron.schedule(
  'ceifar-jobs-orfaos',
  '*/10 * * * *',
  $$ select posta_ai.ceifar_jobs_orfaos(); $$
);
