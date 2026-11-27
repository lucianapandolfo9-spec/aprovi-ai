-- aprovi.ai — migration 8 (27/11/2026): canais de postagem por marca no painel.
--
-- Pedido da Luciana: "nem todos os clientes têm TikTok; o aprovi.ai tem que mostrar
-- onde cada marca posta". A fila (rpc_proximo_job_publicacao, migration 7) já respeita:
--   Instagram/Facebook → social_accounts.publicar_instagram / publicar_facebook
--   TikTok/YouTube     → contas_rede.ativo AND publicar_por_padrao (só reel)
--   por post           → posts.canais_desligados
-- TikTok/YouTube já têm RPC de painel (posta_ai_admin_contas_rede / _ajustar_conta_rede).
-- Faltava o mesmo para Instagram/Facebook. Esta migration é SÓ ADITIVA: 2 funções novas,
-- nenhuma tabela, coluna ou função existente alterada.

-- Lê o estado dos canais da Meta de uma marca (sem token).
create or replace function public.posta_ai_admin_canais_meta(p_brand_id uuid)
 returns table(tem_conta boolean, tem_instagram boolean, tem_facebook boolean,
               publicar_instagram boolean, publicar_facebook boolean)
 language sql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
  select true,
         coalesce(sa.ig_user_id, '') <> '',
         coalesce(sa.page_id, '') <> '',
         coalesce(sa.publicar_instagram, false),
         coalesce(sa.publicar_facebook, false)
  from posta_ai.social_accounts sa
  where sa.brand_id = p_brand_id and public.posta_ai_is_admin()
  limit 1;
$function$;

-- Liga/desliga Instagram ou Facebook numa marca. Recusa ligar canal sem conta conectada,
-- para não gerar post que falha na hora de publicar.
create or replace function public.posta_ai_admin_ajustar_canal_meta(
  p_brand_id uuid, p_canal text, p_ligado boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'posta_ai'
as $function$
declare
  v_sa posta_ai.social_accounts;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  if p_canal not in ('instagram', 'facebook') then raise exception 'canal invalido'; end if;
  if p_ligado is null then raise exception 'informe ligado true/false'; end if;

  select * into v_sa from posta_ai.social_accounts where brand_id = p_brand_id limit 1;
  if not found then raise exception 'marca sem conta da Meta conectada'; end if;

  if p_ligado and p_canal = 'instagram' and coalesce(v_sa.ig_user_id, '') = '' then
    raise exception 'marca sem Instagram conectado';
  end if;
  if p_ligado and p_canal = 'facebook' and coalesce(v_sa.page_id, '') = '' then
    raise exception 'marca sem Pagina do Facebook conectada';
  end if;

  update posta_ai.social_accounts
     set publicar_instagram = case when p_canal = 'instagram' then p_ligado else publicar_instagram end,
         publicar_facebook  = case when p_canal = 'facebook'  then p_ligado else publicar_facebook  end,
         atualizado_em = now()
   where id = v_sa.id;
end;
$function$;

revoke all on function public.posta_ai_admin_canais_meta(uuid) from public, anon;
revoke all on function public.posta_ai_admin_ajustar_canal_meta(uuid, text, boolean) from public, anon;
grant execute on function public.posta_ai_admin_canais_meta(uuid) to authenticated;
grant execute on function public.posta_ai_admin_ajustar_canal_meta(uuid, text, boolean) to authenticated;
