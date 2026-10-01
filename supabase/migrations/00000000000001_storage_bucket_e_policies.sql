-- =====================================================================
-- aprovi.ai — bucket de mídia e policies de Storage
-- =====================================================================
-- Extraído de storage.buckets e pg_policies (storage.objects) do projeto
-- tscnqvuzlfagotirgjbz em 01/10/2026.
-- =====================================================================


-- ---------------------------------------------------------------------
-- BUCKET
-- ---------------------------------------------------------------------
-- ⚠️ DIVERGÊNCIA DELIBERADA DE PRODUÇÃO — a única deste repo.
--
-- Em produção, `posta-ai-media` tem file_size_limit = NULL e
-- allowed_mime_types = NULL. Isso é pendência reconhecida (nº2 do
-- PROJETO.md, aberta desde 11/set): o bucket aceita arquivo de qualquer
-- tamanho e qualquer tipo, incluindo coisa que o aprovi.ai nunca publica.
--
-- Instância nova nasce CERTA:
--   * 50 MB  = 52428800 bytes — teto prático do plano free do Supabase
--   * as 6 mime types que a Edge Function emitir-url-upload já valida
--     (mp4, mov, jpg/jpeg, png, webp) — a mesma lista, só movida pra
--     onde o banco também a aplica
--
-- Consertar produção é 1 statement e decisão separada da Luciana.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'posta-ai-media',
  'posta-ai-media',
  true,                 -- leitura pública: a Meta precisa baixar a mídia pela URL
  52428800,
  array['video/mp4', 'video/quicktime', 'image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;


-- ---------------------------------------------------------------------
-- POLICIES em storage.objects
-- ---------------------------------------------------------------------
-- As 4 policies abaixo citam `posta-ai-media` NOMINALMENTE. Isso importa:
-- no projeto de produção o mesmo storage.objects também serve o bucket
-- `contratos`, do Hub Luh Panda, com outras 4 policies. Como todas nomeiam
-- o bucket, não existe policy compartilhada — nada do Hub vaza pra cá.
--
-- 📌 Sobre a falta de `coalesce` em auth.email():
-- Em policy isso é SEGURO, ao contrário do que acontecia em PL/pgSQL.
-- Policy só concede quando a expressão é TRUE; NULL (sem sessão) é tratado
-- como negação. Já num `if not <expr> then raise` do PL/pgSQL, NULL não é
-- false e o bloco não executava — foi exatamente o bug de 29/jul corrigido
-- em posta_ai_is_admin(). Mesma expressão, semânticas diferentes.
--
-- 📌 Nota histórica: as 3 policies de admin são da época em que a Luciana
-- subia mídia por curl autenticado. Hoje o upload passa pela Edge Function
-- emitir-url-upload, que usa service_role e portanto IGNORA RLS. Elas
-- continuam aqui porque continuam em produção — e porque são a rede de
-- segurança se alguém voltar a subir pelo painel autenticado.

create policy "posta_ai public read"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'posta-ai-media'::text);

create policy "posta_ai admin upload"
  on storage.objects for insert
  to authenticated
  with check ((bucket_id = 'posta-ai-media'::text) AND (auth.email() = 'lucianapandolfo9@gmail.com'::text));

create policy "posta_ai admin update"
  on storage.objects for update
  to authenticated
  using ((bucket_id = 'posta-ai-media'::text) AND (auth.email() = 'lucianapandolfo9@gmail.com'::text));

create policy "posta_ai admin delete"
  on storage.objects for delete
  to authenticated
  using ((bucket_id = 'posta-ai-media'::text) AND (auth.email() = 'lucianapandolfo9@gmail.com'::text));


-- ---------------------------------------------------------------------
-- O QUE NÃO VEM NESTE ARQUIVO
-- ---------------------------------------------------------------------
-- Os 49 objetos (vídeos e imagens) que existem no bucket de produção
-- NÃO são copiados. São mídia real de cliente. Uma réplica de
-- desenvolvimento não tem o que fazer com eles, e copiá-los criaria uma
-- segunda cópia de conteúdo de cliente num lugar com menos controle.
--
-- O seed (90000000000000_semente_demo.sql) aponta pra URLs que
-- deliberadamente NÃO EXISTEM, no domínio da própria réplica.
