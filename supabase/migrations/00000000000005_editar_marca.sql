-- Editar marca (nome, handle, fuso, idioma) pelo painel.
-- NAO toca em secret_token (o link ja enviado ao cliente continua valendo),
-- workspace_id nem criado_em. Autorizacao dentro da funcao (posta_ai_is_admin),
-- mesmo padrao das demais RPCs admin; grant restrito como delete_brand.
CREATE OR REPLACE FUNCTION public.posta_ai_admin_update_brand(
  p_brand_id uuid, p_nome text, p_handle text, p_timezone text, p_idioma text)
 RETURNS posta_ai.brands
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare v_brand posta_ai.brands;
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  if coalesce(btrim(p_nome), '') = '' then raise exception 'nome obrigatorio'; end if;

  update posta_ai.brands
     set nome     = btrim(p_nome),
         handle   = nullif(btrim(coalesce(p_handle,'')), ''),
         timezone = coalesce(nullif(btrim(coalesce(p_timezone,'')), ''), timezone),
         idioma   = coalesce(nullif(btrim(coalesce(p_idioma,'')), ''), idioma)
   where id = p_brand_id
   returning * into v_brand;

  if v_brand.id is null then raise exception 'marca nao encontrada'; end if;
  return v_brand;
end;
$function$;

revoke all on function public.posta_ai_admin_update_brand(uuid, text, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_update_brand(uuid, text, text, text, text) to authenticated;
grant execute on function public.posta_ai_admin_update_brand(uuid, text, text, text, text) to service_role;
