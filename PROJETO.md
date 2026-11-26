# aprovi.ai — documento mestre (estado atual)

> **Ler só isto pra retomar.** Enxugado em 26/11/2026: ficou só o que vale hoje.
> O histórico completo (versões antigas deste arquivo, bugs e investigações) está no
> `git log -- PROJETO.md` e no vault, em `Luh Panda/Dev/Sistemas/aprovi.ai/Changelog.md`.
> Instalação e réplica do backend: `README.md`.

## Em 1 minuto

- **O que é:** o cliente aprova (ou pede ajuste em) cada post por um link secreto, sem
  login, e o sistema **publica sozinho** no Instagram na hora marcada.
- **De quem:** ferramenta interna da **Lotta** (empresa da Luciana) e da Luh Panda.
  Não é vendida como produto: prioriza o que tira trabalho manual, não o que deixaria vendável.
- **Identidade:** **Lotta** desde 26/11/2026 (ícone, cores, fonte). O nome continua aprovi.ai.
- **No ar:** https://luhpanda.online (GitHub Pages; o que entra no `main` vai pro ar em ~1 min,
  com cache de 10 min).
  - `index.html`: painel da Luciana (login por código no e-mail, marcas, kanban, upload, agendar)
  - `cliente.html?t=<token>`: tela do cliente (token secreto por marca, sem login)
- **Repo:** `~/Downloads/Luh Panda/aprovi-ai` → `github.com/lucianapandolfo9-spec/aprovi-ai` (público).
- **Backend:** Supabase **`HUB Luh Panda`** (`tscnqvuzlfagotirgjbz`), schema **`posta_ai`**
  (o nome antigo "Posta Aí" ficou só nos internos: schema, funções `posta_ai_*` e bucket
  `posta-ai-media`; **não renomear**). Backend versionado em `supabase/`.
- **MCP:** `supabase-aprovi` (execute_sql, edge functions) aponta pra esse projeto.

## Marcas hoje (conferido no banco em 26/11/2026)

5 marcas. A Gigi (Lymphatic by Gigi) foi **apagada por inteiro** em 26/11/2026 (cliente encerrada).

| Workspace | Marca | IG ligado | Observação |
|---|---|---|---|
| Lotta | Agência Lotta | ✅ | |
| Lotta | Pandoka | ❌ | falta ligar o Instagram (`social_accounts`), ver nota da Pandoka no vault |
| Luh Panda | Luh Panda | ✅ | |
| Luh Panda | Certo Agro | ✅ | story de rodízio diário (cron) |
| Palácio dos Esportes | Palácio dos Esportes | ✅ | entra mídia pela pasta do Drive (robô n8n) |

Um **único token de Usuário do Sistema** (não expira) no Vault serve todas as marcas:
cada `social_accounts` só aponta `ig_user_id`/`page_id` pro mesmo `token_secret_id`.
**Nunca gerar token por cliente.**

## Fluxo de um post

`rascunho → em_aprovacao → aprovado | ajuste_pedido → agendado → publicando → publicado | falhou`

1. Painel: "+ Novo conteúdo" (vários arquivos = carrossel), legenda, "Enviar pra aprovação".
2. Cliente: muda só o texto? Edita a legenda e **Aprovar** (vale na hora). `ajuste_pedido` é
   **só para mexer na mídia**, nunca na legenda (comentário obrigatório).
3. Painel: **Agendar** (só depois de aprovado, no fuso da marca).
4. `pg_cron` publica quando `agendado_para` vence. **Aprovado não publica sozinho.**

Legenda = corpo do post (`post_captions`, versionado) + **assinatura padrão** da marca
(`caption_blocks`, o cliente edita e vale pra todo post futuro).

## Publicação automática (Supabase, sem n8n)

| Peça | O que faz |
|---|---|
| Edge Function `publicar-posts-agendados` | pega 1 post vencido (`rpc_proximo_post_agendado`, `for update skip locked`), publica na Graph API, grava em `rpc_marcar_resultado_publicacao` |
| cron `publicar-posts-agendados-job` | a cada 10 min |
| cron `ceifar-jobs-orfaos` | a cada 10 min marca como falho o job preso em andamento (Edge Function no plano free morre em ~150s sem passar pelo `catch`). **Não reagenda sozinho**, porque a mídia pode já ter ido ao ar |
| crons `story-rodizio-certo-agro-*` | story diário de rodízio do Certo Agro |
| Edge Function `limpar-midia-publicada` | limpa do Storage a mídia já publicada |

- **Formatos:** 1 vídeo = REELS · 1 imagem = IMAGE · 2 a 10 arquivos = CAROUSEL · formato story = STORIES (sem legenda, só o 1º arquivo).
- **Story companheiro:** todo reel/feed publicado gera sozinho um story pra **+1 dia** (título com sufixo `— Story (auto)`; rodízio usa `— Story (rodízio)`). A tela do cliente lê esses sufixos: **mudar o sufixo no SQL quebra o aviso na tela**.
- Falha limpa (vira `falhou` com motivo em `publish_jobs.erro`): post sem arquivo, carrossel com mais de 10.

## Subir mídia

- **Palácio dos Esportes:** salvar em `Meu Drive/aprovi.ai — entrada/Palácio dos Esportes`
  (`feed__x.png`, `story__x.png`, `reel__x.mp4`). O robô n8n (`8EBJVESKkjwKJ1JM`, a cada 15 min)
  sobe e cria o post em aprovação. Detalhe: vault `Aprovi.ai — Pasta do Drive para aprovação (23-11-2026)`.
- **Demais marcas:** Edge Function `emitir-url-upload` (URL assinada de ~2h, header `x-upload-secret`;
  o Vault guarda só o SHA-256). Upload por marca via n8n está desenhado (D1 a D8, aguardando a Luciana):
  vault `Aprovi.ai — upload sem script (16-11-2026)`.
- Bucket `posta-ai-media`: leitura pública, **50 MB por arquivo**, só mp4/mov/jpeg/png/webp.
  Vídeo grande: comprimir antes.

## Segurança (não negociável)

- **Nenhuma tabela acessível pela API.** Tudo passa por função `SECURITY DEFINER` em `public`;
  RLS nega tudo.
- **Admin:** `posta_ai_is_admin()` com `coalesce(auth.email(), '') = '<e-mail dela>'`.
  **Sempre `coalesce`**: sem ele, `NULL = x` deixa anônimo passar (bug real de 29/07).
- **Cliente:** o token (`?t=`) é validado dentro de cada função (`posta_ai_brand_from_token`),
  e todo post é reconferido contra a marca do token.
- Token da Meta **só no Vault**, decriptado dentro da RPC.
- Testar segurança com `curl` na API, como atacante sem sessão. Não só clicando na tela.

## App instalável (PWA) e tela do cliente

- Dois apps separados: `manifest.webmanifest` (painel, id `aprovi-painel`) e
  `manifest-cliente.webmanifest` (cliente, id `aprovi-cliente`).
- `sw.js` (hoje **v3**): só cacheia arquivo estático próprio, **network-first**; Supabase,
  Storage e vídeo (`.mp4`, `Range`) passam direto. Cache **sem query string**, pra o token
  nunca ser gravado. **Subir a `VERSION` quando trocar ícone ou shell.**
- **Token no app instalado:** Android instala pelo manifest e reusa o token do `localStorage`.
  **iPhone não recebe manifest de propósito** (storage separado do Safari): salva a URL com
  `?t=` e usa as metas `apple-*`. **Nunca pôr o token no manifest.**
- Abrir o link de outra marca no mesmo aparelho troca a marca do app instalado.
- **Tutorial de instalar:** faixa no topo do feed, só no celular e fora do app. Passos por
  navegador (Safari e Chrome no iPhone, Chrome e Samsung no Android), aviso pra quem abriu
  dentro do Instagram ou WhatsApp, botão nativo no Android. "Agora não" vira link no rodapé.
  Vídeo: `assets/tutorial/instalar-iphone.mp4` (13s). **O botão só aparece se o arquivo existir**
  (`instalar-android.mp4` ainda não existe).
- Tela do cliente: selo de formato em todo card (`Carrossel · 5 slides`, `Reel`, `Story`) e
  galeria com swipe. Capa igual não identifica formato: **a tela sempre diz o formato em texto**.

## Identidade da Lotta (26/11/2026)

- **Ícones:** `assets/lotta.svg` (o mesmo do site agencialotta.com.br: "L" branco, ponto
  amarelo, roxo `#680076`), `lotta-square.svg` (iPhone) e `lotta-maskable.svg` (Android,
  conteúdo a 70%). PNGs e `favicon.ico` gerados pelo Chrome headless (o `magick` estraga SVG).
- **Cores:** tokens do design system do site (`--lt-*`) no `:root` do `style.css`. Roxo
  `#68006f` / `#7a00d6`, **amarelo `#ffd600` como destaque**, fundo `#0b0215`, superfície
  `#1a0731`, borda `#3d1a6b`. Fonte **Montserrat**.
- **Prévia de link (WhatsApp):** `assets/og-lotta.jpg` (1200x630) com metas `og:*`, **sem
  `og:url`** (pra o token não ir pra prévia). O WhatsApp guarda a prévia por link: link já
  enviado antes ganha prévia nova com `&v=2` no fim.
- iPhone com o app já instalado só troca o ícone **reinstalando**.

## Lições que valem pra qualquer mudança

- Texto que o usuário precisa digitar de volta (confirmação de exclusão) **não pode herdar
  `text-transform`**. Comparar sem diferenciar maiúscula.
- Código novo colado depois de um teste verde precisa do próprio teste.
- Excluir marca = hard delete em cascata (`posta_ai_admin_delete_brand`), com confirmação
  digitando o nome. Apagar os arquivos do Storage antes (`posta_ai_admin_list_brand_asset_urls`).
- **Onboarding Meta de cliente novo:** a Página e o IG precisam estar **atribuídos ao Usuário
  do Sistema** "Luh Panda - BMS Internas". Só compartilhar como parceiro dá erro 10. Passo a
  passo completo: skill `aprovi-ai-postagem-automatica`, que também guarda o
  `subir-midia.sh` e os segredos locais em `secrets/` (fora de qualquer repo).
- Git: tudo por branch e PR; o merge é clique da Luciana (`gh pr merge` é bloqueado).

## Regras que não podem quebrar

- **Fuso sempre na marca** (`brands.timezone`), nunca global.
- **Sem auto-aprovação por tempo.** Quem decide é sempre o cliente.
- Claude **nunca clica em publicar ou agendar** no lugar do cliente final.
- Toda mudança de status fica auditada (`post_events`, `post_captions` versionada).

## Pendências (26/11/2026)

- Pandoka: ligar o Instagram (acesso Meta com a Luciana).
- TikTok e YouTube Shorts: desenho fechado, nada construído. Vault `TikTok e YouTube no aprovi.ai — Desenho (grill 26-11-2026)`.
- Upload por marca via n8n: aguarda decisões D1 a D8.
- Vídeo do tutorial para Android (se ela gravar).
- O maior buraco de produto: **relatório pós-publicação** (alcance, salvamentos), hoje inexistente.
- Notificação de conteúdo novo: não existe. O encaixe é um webhook em `post_events` → n8n + Evolution.
