# aprovi.ai — portal de aprovação de conteúdo

**Documento mestre — ler primeiro ao retomar.**

Produto próprio da Luh Panda (nome comercial: **aprovi.ai**, ex-"Posta Aí"): portal
onde o cliente aprova (ou pede ajuste em) cada criativo antes de ir pro ar, sem
WhatsApp bagunçado nem print perdido. Nasceu do projeto da Gigi (Lymphatic by Gigi),
mas foi desenhado desde a primeira tabela pra aguentar dezenas de clientes e, no
futuro, ser vendido pra outras agências. Hospedado em domínio próprio desde
24/ago/2026 — ver URL publicada abaixo.

**Nota técnica:** o rename foi só de marca/nome visível. Por baixo, Supabase ainda
usa os nomes antigos (`posta_ai` como schema, funções `posta_ai_*`, bucket
`posta-ai-media`) — são internos, invisíveis pro usuário, e renomear exigiria
migração de banco em produção sem necessidade real. Não renomear isso sem motivo forte.

## Onde está tudo

- **Repo local:** `/Users/luhpanda/Downloads/Luh Panda/aprovi-ai`
- **Remote:** `https://github.com/lucianapandolfo9-spec/aprovi-ai` (branch `main`, **repo público** — necessário pro GitHub Pages grátis; seguro porque a chave anon do Supabase é feita pra ficar exposta, e todo acesso passa por RLS + funções travadas, nunca pela chave)
- **URL publicada:** https://luhpanda.online/ (domínio próprio, HTTPS forçado, cert válido até
  22/11/2026). Link antigo `lucianapandolfo9-spec.github.io/aprovi-ai/` segue funcionando —
  redireciona sozinho pro domínio novo, não precisa reenviar link nenhum por causa disso.
  🔴 **Esse domínio ANTES redirecionava `luhpanda.online` → `luhpanda.com.br`** (repo
  `luhpanda-online-redirect`, código preservado lá caso precise reativar) — a partir de
  24/ago/2026 ele hospeda o aprovi.ai direto, não redireciona mais pro site principal.
  DNS não precisou de nenhuma mudança (já apontava pro GitHub Pages desde o redirect antigo).
  - `index.html` — painel da Luciana (login, marcas, kanban, upload, edição)
  - `cliente.html?t=<token>` — tela do cliente (link secreto por marca, sem login)
- **Backend:** Supabase, projeto `arroba-certa` (`tscnqvuzlfagotirgjbz`) — **schema isolado `posta_ai`**, não mexe em nada do @certo. Motivo: conta free só permite 2 projetos Supabase ativos por org, já ocupados por `auditor-folha-capitalize` e `arroba-certa`.
- **Storage:** bucket `posta-ai-media` (público pra leitura; upload só autenticado como admin).

## Por que essa estrutura (decisões tomadas)

1. **Build vs. buy dividido em duas camadas.** Aprovação = ativo próprio (baixo custo, vendável). Publicação automática = infraestrutura chata (App Review da Meta, tokens, refresh) — não vale reinventar. Fase 1 é só aprovação; fase 2 pluga publicação.
2. **Metricool descartado por enquanto.** Só 1 marca conectada hoje (a pessoal da Luciana) — plano atual não comporta multi-marca. Entra quando tiver volume de cliente que justifique assinar.
3. **App próprio na Meta em vez de assinar Metricool.** Com poucos clientes, contas entram como *tester* do app em modo desenvolvimento — publica sem precisar de App Review. App Review só vira obrigatório ao atender conta de fora (agência terceira).
4. **`workspace_id`/multi-tenant desde a primeira tabela**, mesmo com um cliente só rodando hoje — é barato fazer agora, caro fazer depois. Estrutura aguenta 30+ clientes sem mudança de schema.
5. **Sem login pro cliente.** Link fixo secreto por marca (`brands.secret_token`), reenviado sempre o mesmo pelo WhatsApp. Zero fricção — decisão validada com a Gigi em mente ("ela não vai criar conta, ela tá colapsando às 21h40").
6. **Você agenda, o cliente só aprova.** Sem tela de calendário do lado dele — menos campo, menos confusão.
7. **Notificação de conteúdo novo:** nenhuma automática ainda (você manda o link na mão pelo WhatsApp). Ponto de encaixe pro n8n + Evolution já pré-cabeado (ver Roadmap).

## Modelo de dados (schema `posta_ai`)

```
workspaces        id, nome
brands            id, workspace_id, nome, handle, timezone, idioma, secret_token
caption_blocks    id, brand_id, tipo, conteudo, ativo        -- "assinatura padrão", editável pelo cliente
posts             id, brand_id, titulo_interno, formato, status, agendado_para
post_assets       id, post_id, ordem, tipo, url, thumb_url, duracao_seg
post_captions     id, post_id, versao, corpo, autor           -- histórico de toda edição de legenda
post_comments     id, post_id, autor, texto
post_events       id, post_id, de_status, para_status, autor  -- auditoria de toda mudança de status
```

**Legenda em duas partes:** corpo (`post_captions.corpo`, varia por post) + assinatura padrão
(`caption_blocks.conteudo`, fixa por marca, editável pelo cliente e propaga sozinha pra
todo post futuro). Mesma lógica do `CTAEnd.tsx` do projeto Remotion da Gigi, aplicada à legenda.

**Máquina de status:**
`rascunho → em_aprovação → aprovado | ajuste_pedido` (ajuste volta pro loop) `→ agendado → publicando → publicado | falhou`

🔴 **`ajuste_pedido` é especificamente "precisa editar o vídeo" — nunca legenda**
(homologado 24/ago/2026). Mudança só de texto **não passa por aqui**: o
cliente edita o campo de legenda na tela dele e clica "Aprovar" — isso já
salva a versão editada (`post_captions`, `autor='aprovador'`) **e** já muda o
post pra `aprovado` na mesma ação, sem nenhuma intervenção do admin. O botão
"Pedir ajuste" do `cliente.html` foi relabelado pra "🎬 Precisa editar o
vídeo" e o campo de comentário (obrigatório nesse caminho) pede
especificamente o que muda no vídeo. Motivo: antes o botão era genérico e
toda solicitação — texto ou vídeo — caía como `ajuste_pedido`, obrigando a
Luciana a ler cada comentário pra descobrir se dava pra resolver na hora ou
se precisava editar vídeo de verdade.

## Segurança — como o acesso é controlado

**Nenhuma tabela é acessível direto via API — só via funções `SECURITY DEFINER` em `public`.**

- **Admin (você):** Supabase Auth (magic link por e-mail) + toda função admin checa
  `posta_ai_is_admin()` = `coalesce(auth.email(), '') = 'lucianapandolfo9@gmail.com'`.
- **Cliente:** sem login — token da URL (`?t=`) é validado dentro da função
  (`posta_ai_brand_from_token`) antes de qualquer leitura/escrita, e todo post é
  reconferido contra a marca do token (não dá pra um token de uma marca mexer em
  post de outra).
- **Storage:** bucket público de leitura; insert/update/delete só pro e-mail admin autenticado.

**⚠️ Bug de segurança real encontrado e corrigido na primeira sessão (29/jul/2026):**
`auth.email()` retorna `NULL` pra requisição anônima. `NULL = 'email'` também dá `NULL`,
e em PL/pgSQL `IF NOT NULL THEN raise exception` **não dispara** (NULL não é true nem
false) — isso deixava qualquer função admin passar direto sem login. Corrigido trocando
pra `coalesce(auth.email(), '') = 'email'`, que sempre resolve pra boolean de verdade.
**Lição:** todo check de auth em Postgres/PL-pgSQL precisa de `coalesce`/`is not distinct
from` — nunca comparação direta que pode virar NULL. Testado com curl direto na API
(bypassando a UI) simulando um atacante sem sessão — é assim que vale testar RLS/RPC
daqui pra frente, não só clicando na tela.

## Como usar hoje (fase 1)

1. Login em `index.html` com o e-mail admin (link mágico).
2. "+ Nova marca" pra cadastrar um cliente novo — copia o link secreto gerado e manda
   uma vez só pelo WhatsApp (fica fixo).
3. "+ Novo conteúdo" — pode selecionar **vários arquivos de uma vez** (vira carrossel
   automaticamente), escreve o corpo da legenda, cria como rascunho.
4. "Enviar pra aprovação" quando estiver pronto pro cliente ver.
5. Cliente abre o link. Se só mudar a legenda, edita e clica "Aprovar" — fica
   aprovado na hora, sem passar pelo admin. "🎬 Precisa editar o vídeo" é só
   pra pedido que precisa de edição de vídeo de verdade (comentário
   obrigatório descrevendo o que muda).
6. **Botão "Abrir" em qualquer card, qualquer status** — mostra os arquivos com link
   de abrir/baixar, legenda editável (dá pra corrigir mesmo depois de aprovado),
   assinatura padrão de referência, e "Copiar legenda + assinatura" pra colar direto
   no Instagram na hora de postar manualmente. É o fluxo real de hoje: você pega o
   conteúdo aprovado aqui e sobe na mão, até a fase 2 automatizar isso.
7. "Agendar" (só depois de aprovado) — define data/hora no fuso da própria marca.

## Cliente-teste em produção

**Lymphatic by Gigi** é o primeiro caso real, rodando desde 29/jul/2026 — primeiro
conteúdo aprovado de ponta a ponta foi o recap do evento Juni Block Party.

## Roadmap — Fase 2 (publicação automática)

🔴 **EM ANDAMENTO desde 21/08/2026 — cliente-piloto: Lymphatic by Gigi. Ver
status vivo na skill `lymphatic-by-gigi` (seção "Estado da automação via
API"), aqui fica só o design técnico, que não muda por sessão.**

**Decisão de arquitetura (revista 23/08, substitui a linha antiga de
"App próprio + tester"):** em vez de cadastrar app no Meta for Developers e
adicionar cada cliente como *tester*, usar **Usuário do Sistema por
Business Manager** — mais direto quando a agência já administra o Business
Manager do cliente (é o caso da Gigi). Passo a passo:
1. Business Manager do cliente precisa estar **verificado**
   (`Configurações → Informações da empresa → Iniciar verificação`) — sem
   isso o botão de criar Usuário do Sistema fica desabilitado. Pede dados
   da empresa + confirmação por telefone/e-mail + documento (LLC/EIN/
   business license/DBA) se não achar registro público automaticamente.
2. Criar o Usuário do Sistema em Business Settings → Usuários do sistema,
   atribuir acesso à Página e à conta do Instagram do cliente como ativos.
3. Gerar token escolhendo **"Never" na expiração** (não os 60 dias
   padrão), com permissões `instagram_basic`, `instagram_content_publish`,
   `pages_show_list`, `pages_read_engagement`, `business_management`.
   Não expira por tempo — só por revogação manual, mudança de dono do
   ativo, ou ação de política do Meta.

**Pré-requisito por cliente:** Instagram Business/Creator vinculado a uma
Página do Facebook dentro do Business Manager. **Não presumir que falta**
— checar primeiro (`Configurações → Contas do Instagram → aba "Ativos
conectados"`) antes de tratar como pendência; no caso da Gigi já estava
resolvido, só não tinha sido conferido.

**Tabelas que faltam** (schema `posta_ai`, nenhuma outra muda):
```
social_accounts   id, brand_id, ig_user_id, page_id, access_token (cifrado),
                  expira_em, conectado_em
publish_jobs      id, post_id, tentativa, ig_creation_id, ig_media_id,
                  status, erro, criado_em, publicado_em
```

**Onde roda a publicação:** aprovi.ai é site estático (GitHub Pages), não
tem servidor próprio — quem executa é **n8n**, workflow agendado
(a cada 5-15min).

**Gatilho correto — 🔴 corrige a versão antiga deste roadmap:**
publicar quando **`agendado_para` vence num post com status `agendado`**,
**não** quando o post vira `aprovado`. Aprovado só significa "pode
agendar" — não significa "é hora de postar". O n8n consulta `posts` onde
`status='agendado' AND agendado_para <= now()` (respeitando `brands.timezone`),
chama a Instagram Content Publishing API (`POST /{ig-user-id}/media` →
pra vídeo, aguardar `status_code=FINISHED` → `POST /{ig-user-id}/media_publish`),
grava resultado em `publish_jobs` e atualiza `posts.status` via função
`SECURITY DEFINER` chamada com token de serviço do n8n (nunca a anon key
do site).

**Melhorias de produto desenhadas em paralelo (não dependem do token,
podem ser codadas a qualquer momento):**
1. **Legenda editável em post já aprovado** — hoje `cliente.html` só
   mostra legenda editável em posts `em_aprovacao`/`ajuste_pedido`; posts
   `aprovado`/`agendado` caem no Histórico só-leitura. Fix: nova função
   `posta_ai_client_update_caption(token, post_id, legenda)` (mesmo padrão
   de segurança de `posta_ai_client_update_signature`, não toca status) +
   botão "✏️ Editar legenda" inline no Histórico pra esses dois status.
   Elimina o vai-e-volta de reabrir aprovação só por causa de texto.
2. **Aviso de vídeo sem áudio no upload** — checagem no navegador
   (`<video>` + `audioTracks`) ao anexar arquivo em "Novo conteúdo" no
   `index.html`. Não bloqueia, só avisa antes de mandar pra aprovação.

## Roadmap — notificação via n8n (não construído ainda, de propósito)

Toda mudança de status já grava em `post_events`. Plugar n8n + Evolution é só apontar
um webhook do Supabase nessa tabela — zero refatoração, nenhuma tabela nova.

## Regras que não podem quebrar

- **Fuso sempre no nível da marca** (`brands.timezone`), nunca configuração global —
  Gigi é `America/Los_Angeles`, você é `America/Recife`.
- **Sem auto-aprovação por tempo.** A decisão final é sempre do cliente — nunca
  adicionar "aprova sozinho depois de X dias".
- Ao adicionar qualquer função nova que faça checagem de admin/permissão: usar
  `coalesce()` — ver o bug de segurança documentado acima antes de repetir o padrão.
