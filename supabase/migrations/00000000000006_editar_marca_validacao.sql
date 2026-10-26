-- Editar marca: validacao dos campos (substitui o corpo da funcao da 05).
-- Motivo: fuso em texto livre aceitou 'Brasil/Recife' (nao e fuso IANA). As
-- funcoes de story (migration 04) fazem `at time zone brands.timezone`, e o
-- Postgres levanta 'time zone "..." not recognized' com valor invalido.
-- Agora: nome obrigatorio, handle sem @ e sem espaco, fuso tem que existir em
-- pg_timezone_names, idioma no formato pt / pt-BR. Mesma assinatura e mesmos
-- grants da 05; continua sem tocar em secret_token, workspace_id e criado_em.
CREATE OR REPLACE FUNCTION public.posta_ai_admin_update_brand(
  p_brand_id uuid, p_nome text, p_handle text, p_timezone text, p_idioma text)
 RETURNS posta_ai.brands
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'posta_ai'
AS $function$
declare
  v_brand  posta_ai.brands;
  v_nome   text := btrim(coalesce(p_nome, ''));
  v_handle text := nullif(btrim(coalesce(p_handle, '')), '');
  v_tz     text := nullif(btrim(coalesce(p_timezone, '')), '');
  v_idioma text := nullif(btrim(coalesce(p_idioma, '')), '');
begin
  if not public.posta_ai_is_admin() then raise exception 'forbidden'; end if;
  if v_nome = '' then raise exception 'nome obrigatorio'; end if;
  if length(v_nome) > 120 then raise exception 'nome muito longo (max 120)'; end if;
  if v_handle is not null and v_handle !~ '^[A-Za-z0-9._]{1,30}$' then
    raise exception 'handle invalido: sem @, sem espaco (letras, numeros, ponto e underline)';
  end if;
  if v_tz is not null
     and not exists (select 1 from pg_catalog.pg_timezone_names where name = v_tz) then
    raise exception 'fuso invalido: % (use o formato IANA, ex: America/Recife)', v_tz;
  end if;
  if v_idioma is not null and v_idioma !~ '^[a-z]{2,3}(-[A-Z]{2})?$' then
    raise exception 'idioma invalido: use pt, en ou pt-BR';
  end if;

  update posta_ai.brands
     set nome     = v_nome,
         handle   = v_handle,
         timezone = coalesce(v_tz, timezone),
         idioma   = coalesce(v_idioma, idioma)
   where id = p_brand_id
   returning * into v_brand;

  if v_brand.id is null then raise exception 'marca nao encontrada'; end if;
  return v_brand;
end;
$function$;

revoke all on function public.posta_ai_admin_update_brand(uuid, text, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.posta_ai_admin_update_brand(uuid, text, text, text, text) to authenticated;
grant execute on function public.posta_ai_admin_update_brand(uuid, text, text, text, text) to service_role;
