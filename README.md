# aprovi.ai

Aprovação e publicação automática de conteúdo social. A editora sobe o vídeo e
escreve a legenda; o cliente aprova por um link secreto, sem login; o sistema
publica sozinho no Instagram na hora marcada.

Ferramenta interna da [Luh Panda](https://luhpanda.com.br). Não é vendida como
produto — decisão de 11/set/2026, registrada no `PROJETO.md`. Isso muda a
prioridade: vale o que reduz trabalho manual, não o que deixaria vendável.

- **Painel da editora:** `index.html` — login por e-mail, gestão de marcas, kanban, upload, edição de legenda
- **Portal do cliente:** `cliente.html?t=<token>` — sem login; a autorização é o token na URL
- **No ar em:** https://luhpanda.online (GitHub Pages, por isso este repo é público)

---

## Como está montado

```
Front (HTML/CSS/JS puro, sem build)
  └─ supabase-js via CDN, usando a anon key  →  RPCs em `public`
                                                   │
                                      SECURITY DEFINER
                                                   │
                                                   ▼
                                       schema `posta_ai`
                                 (10 tabelas, RLS nega-tudo,
                                  inalcançável por API direta)

pg_cron ──10min──▶ Edge Function `publicar-posts-agendados`
                      │  (service_role)
                      ├─ rpc_proximo_post_agendado()  → lock + token do Vault
                      ├─ Instagram Content Publishing API
                      └─ rpc_marcar_resultado_publicacao()

Upload: `emitir-url-upload` devolve URL assinada escopada a 1 arquivo.
        A service_role nunca sai da função.
```

**A regra de ouro da arquitetura:** nenhuma tabela é exposta via PostgREST.
O schema `posta_ai` não tem `USAGE` para `anon` nem `authenticated`, e as 10
tabelas têm RLS ligado **com zero policies** — o que nega tudo. Todo acesso
passa por função `SECURITY DEFINER` em `public`, que carrega a autorização
dentro dela. Se você encontrar RLS sem policy aqui, **não é lacuna** — é o
desenho.

### A máquina de estados

```
rascunho → em_aprovacao → aprovado | ajuste_pedido
                       → agendado → publicando → publicado | falhou
```

`ajuste_pedido` significa **especificamente "precisa refazer o vídeo"**.
Mudança só de legenda nunca passa por ali: o cliente edita a legenda **e**
aprova na mesma ação (`posta_ai_client_decide` aceita `p_legenda`), e a nova
versão entra com `autor='aprovador'`.

### As duas automações de story

São **independentes** e usam **colunas diferentes**, de propósito — cada uma
tem a própria guarda anti-duplicata:

| Coluna | Automação | Quem dispara |
|---|---|---|
| `posts.post_origem_id` | story **companheiro**, D+1 depois de um reel/feed publicar | `rpc_marcar_resultado_publicacao` |
| `posts.story_rodizio_de` | story **do rodízio diário**, reaproveita o vídeo há mais tempo sem ir pra story | `posta_ai.enfileirar_story_diario` via pg_cron |

⚠️ Se alguém unificar as duas colunas, uma das automações para de funcionar em
silêncio.

---

## Estrutura do repo

```
.
├── index.html  cliente.html  config.js  style.css  CNAME   ← front
├── PROJETO.md                      ← documento mestre: decisões e pendências
├── README.md                       ← este arquivo
└── supabase/
    ├── config.toml                 ← verify_jwt por função
    ├── migrations/
    │   ├── 00000000000000_fundacao_posta_ai.sql      ← schema inteiro
    │   ├── 00000000000001_storage_bucket_e_policies.sql
    │   ├── 00000000000002_cron_jobs.sql             ← TODO COMENTADO
    │   └── 90000000000000_semente_demo.sql          ← semente sintética
    ├── seed.sql                    ← só um ponteiro; leia o porquê lá
    ├── functions/
    │   ├── publicar-posts-agendados/index.ts
    │   └── emitir-url-upload/index.ts
    └── verificacao/
        └── _verificacao_pos_migracao.sql
```

### Sobre as migrations: é um retrato, não um histórico

O schema foi construído entre 29/jul e 14/set/2026 por ~20 migrations aplicadas
direto no banco, que **nunca existiram como arquivo**. Pior: elas estão
intercaladas cronologicamente com as migrations de dois outros sistemas (Certo
Agro e Hub Luh Panda) que dividiam o mesmo projeto Supabase. Replayá-las contra
um Postgres limpo não funciona — referenciam objetos criados pelas migrations
dos outros dois.

Então `00000000000000_fundacao_posta_ai.sql` é o **estado final**, extraído por
introspecção (`pg_get_functiondef`, `pg_get_constraintdef`, `pg_policies`,
`aclexplode`) em 01/10/2026. O histórico datado **não é passo pendente**.

> Mesmo padrão que funcionou na migração do Certo Agro em 30/09/2026.

---

## Replicar numa organização Supabase nova

Objetivo: levantar uma instância funcional **sem nenhum dado de cliente** e
**incapaz de publicar** no Instagram de quem quer que seja.

### 0. Pré-requisitos

```bash
brew install supabase/tap/supabase   # precisa ser >= 2.118
supabase login
```

**Docker não é necessário.** `db push` fala direto com o banco e
`functions deploy` empacota localmente. Só `supabase start` (stack local)
exigiria Docker, e não vamos usar.

### 1. Criar o projeto

```bash
supabase projects create aprovi-ai-replica \
  --org-id <ORG_ID> \
  --region sa-east-1 \
  --plan free \
  --db-password '<GERE LOCALMENTE>'
```

Gere a senha localmente (`openssl rand -base64 32`) e guarde no gerenciador de
senhas. **Nunca** no repo, nunca em arquivo, nunca em chat.

### 2. Clonar e linkar

```bash
git clone https://github.com/lucianapandolfo9-spec/aprovi-ai
cd aprovi-ai
supabase link --project-ref <REF_NOVO>
```

### 3. Aplicar o schema

```bash
supabase db push
```

Aplica `supabase/migrations/*` em ordem de nome — inclusive a semente
(prefixo `9`, sempre a última).

As extensões `pgcrypto` e `uuid-ossp` são criadas pela primeira migration.
`pg_cron` e `pg_net` **não são necessários na réplica**: a migration de cron
está inteiramente comentada.

### 4. Deploy das Edge Functions

```bash
supabase functions deploy publicar-posts-agendados --project-ref <REF_NOVO>
supabase functions deploy emitir-url-upload        --project-ref <REF_NOVO>
```

⚠️ **Não passe `--no-verify-jwt` nem `--verify-jwt`.** O valor vem do
`supabase/config.toml`. Passar na linha de comando faz os dois divergirem — e
aí a função fica aberta, ou fica dando 401, e ninguém sabe qual é o certo.

### 5. Secrets: nenhum

As duas funções usam **somente** `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY`,
e os dois são injetados pelo runtime do Supabase. **Não rode
`supabase secrets set` para nenhum deles** — setar manualmente pode sobrescrever
com valor errado.

Não há nenhum secret customizado. Se no futuro houver, declare aqui com
placeholder, nunca com valor:

```bash
# supabase secrets set --project-ref <REF> NOME_DO_SECRET='<SUBSTITUIR>'
```

### 6. Vault: gere um segredo de upload NOVO

A Edge Function `emitir-url-upload` confere o header `x-upload-secret` contra
um SHA-256 guardado no Vault. **Não copie o hash de produção** — hash de
produção numa réplica significa que a réplica aceita o segredo de produção.

```bash
openssl rand -hex 32     # guarde este valor; é o segredo CRU, não commite
```

```sql
select vault.create_secret(
  encode(digest('<VALOR_GERADO_ACIMA>', 'sha256'), 'hex'),
  'aprovi_upload_secret_sha256',
  'SHA-256 do segredo de upload desta replica'
);
```

Detalhes que importam:
- O nome do segredo é **`aprovi_upload_secret_sha256`**, com sufixo. `rpc_validar_upload` busca por esse nome literal.
- O encoding é **hex minúsculo** (a função compara com `lower(trim(...))`).
- O Vault guarda **só o hash**. O valor cru nunca entra no banco.

### 7. Auth

No painel: habilite Email / magic link, e aponte **Site URL** e **Redirect
URLs** pro host do front da réplica.

⚠️ **A UI de admin não é exercitável na réplica.** `posta_ai_is_admin()`
compara com um e-mail literal (`lucianapandolfo9@gmail.com`) — decisão
deliberada, pra a réplica ser idêntica a produção e pra o bug do
`auth.email()` NULL não ter chance de voltar. Para exercitar caminhos de
admin, chame as RPCs com a `service_role` key. **O caminho do cliente (portal
por token) funciona 100%.**

### 8. Front

🔴 **`config.js` contém a URL e a anon key de PRODUÇÃO.** Edite localmente
para apontar pra réplica e **NUNCA dê push dessa alteração**. A branch `main`
é servida pelo GitHub Pages em luhpanda.online — é o portal vivo de uma
cliente real. Um commit repontando o `config.js` apaga o acesso dela.

### 9. Verificar

```bash
# cole o conteúdo de supabase/verificacao/_verificacao_pos_migracao.sql
```

Leia a coluna `veredito`. **Qualquer `FALHOU` é bloqueador.** O bloco C
(INOFENSIVIDADE) é o que prova que a réplica não pode publicar:

| Checagem | Esperado |
|---|---|
| `posta_ai.social_accounts` | 0 linhas |
| `cron.job` | 0 jobs |
| objetos em `posta-ai-media` | 0 |
| segredos com "meta" no Vault | 0 |
| posts `agendado` vencendo em < 1 ano | 0 |
| **`rpc_proximo_post_agendado()`** | **ZERO linha** |

A última fecha o caso: se ela devolver linha, alguma das travas acima não é a
trava que você pensa que é.

Depois rode também o **bloco E** (prova de ataque com `curl`) descrito no fim
do arquivo de verificação. Painel pode esconder o que a API expõe.

### 10. Pegar os links do portal

Os tokens das marcas da semente foram gerados aleatoriamente pelo banco:

```sql
select nome, handle, 'https://<SEU_HOST>/cliente.html?t=' || secret_token as link
from posta_ai.brands order by nome;
```

Trate esses links como senha.

---

## As quatro travas da réplica

Não confie em uma só. São independentes:

1. **`social_accounts` vazia** — sem `ig_user_id`/`token_secret_id`, `rpc_proximo_post_agendado` marca o post como `falhou` e sai antes de falar com a Meta
2. **Nenhum token da Meta no Vault** — não há o que decriptar
3. **Zero cron job** — a migration de agendamento está toda comentada
4. **Todo post `agendado` a 10 anos no futuro** — e os assets apontam pra `demo.invalid`, TLD reservada pela RFC 2606, que por definição nunca resolve

---

## Armadilhas já pagas

Cada uma destas custou tempo. Leia antes de mexer.

**As 3 RPCs sem o prefixo `posta_ai_`.** `rpc_proximo_post_agendado`,
`rpc_marcar_resultado_publicacao` e `rpc_validar_upload` são do aprovi.ai mas
não carregam o prefixo. Qualquer filtro por `posta_ai%` as derruba em
silêncio: o schema aplica limpo, as funções deployam, e só morre quando um
post vence. Trabalhe com lista fechada de nomes, nunca com prefixo.

**`DROP FUNCTION` + `CREATE FUNCTION` reseta os grants.**
`CREATE OR REPLACE FUNCTION` os preserva. Em 01/10/2026 descobriu-se que
`rpc_proximo_post_agendado` — que decripta o token da Meta e **não tem
checagem de autorização interna**, porque o grant é a defesa — estava
executável por `anon`. Ela nasceu correta em 09/09 e foi recriada em 10/09
pela migration `rpc_proximo_post_agendado_suporte_imagem_e_carrossel`,
perdendo o revoke sem aviso. Como a anon key é pública (está no `config.js`
deste repo), qualquer pessoa podia pedir o token da Business Manager central
— expiração "never", cobrindo Instagram, Página **e Ads**.
➜ **Toda migration que recria uma dessas três tem que reemitir o bloco de
grants.** A verificação (B5–B9) afirma isso.

**O bug do `auth.email()` NULL.** `posta_ai_is_admin()` usa
`coalesce(auth.email(), '')`. Sem o `coalesce`, sem sessão, `auth.email()` é
NULL, `NULL = 'x'` é NULL, e `if not NULL then raise` **não entra no bloco** —
então toda função admin passava sem login. Corrigido em 29/jul/2026.
➜ Extraia funções com `pg_get_functiondef`, nunca redigite. A verificação
(B10–B11) afirma que o `coalesce` está lá.
➜ Curiosidade que importa: nas **policies** de Storage a mesma expressão
aparece *sem* `coalesce`, e ali está correto — policy só concede em TRUE, e
NULL é negação. Semânticas diferentes para a mesma expressão.

**`verify_jwt` pode diferir entre funções.** Declare no `config.toml`, não na
CLI.

**Status 200 não prova publicação.** `publicar-posts-agendados` captura erro
de RPC, empurra para `resultados` e **ainda devolve HTTP 200**. Para saber se
publicou de verdade, olhe `posta_ai.publish_jobs`.

**`succeeded` no pg_cron também não prova nada.** O job dispara via `pg_net`,
que é assíncrono — `cron.job_run_details.status = 'succeeded'` significa
apenas que o SQL rodou.

**Os schemas `vault` e `posta_ai` não são expostos via REST.** `sb.schema("vault")`
e `sb.schema("posta_ai")` falham com `Invalid schema` dentro de Edge Function.
Toda leitura passa por RPC `SECURITY DEFINER` em `public`. Isso custou duas
tentativas.

**Nunca persista a `service_role` key em disco.** Ela ignora RLS em todas as
tabelas de todos os clientes. A Edge Function `emitir-url-upload` existe
exatamente para que ninguém precise dela num script local.

---

## Débito conhecido

**~~Exclusão de post falha na maioria dos posts.~~** ✅ Resolvido em
01/10/2026. `posta_ai_admin_delete_post` fazia um `delete` seco e falhava por
violação de FK em **36 de 40 posts** — `publish_jobs_post_id_fkey`,
`posts_post_origem_id_fkey` e `posts_story_rodizio_de_fkey` não têm `ON
DELETE`. As FKs **continuam sem cláusula** de propósito (histórico de
publicação e stories derivados não devem cair em cascata); o conserto foi na
função, que agora desvincula os derivados e apaga `publish_jobs` antes do
post — o mesmo padrão que `posta_ai_admin_delete_brand` já usava.

**Bucket sem limite em produção.** `posta-ai-media` tem `file_size_limit` e
`allowed_mime_types` os dois NULL (pendência nº2 do `PROJETO.md`). A migration
`…0001` cria o bucket **já endurecido** — 50 MB e as 6 mime types que
`emitir-url-upload` valida — então instância nova nasce certa. Produção segue
NULL; consertar lá é 1 statement.

**Sem relatório pós-publicação.** Depois que o post vai ao ar, o sistema não
sabe como ele performou. Chamado no `PROJETO.md` de "o maior buraco de
produto".

**STORIES nunca foi validado contra a API real.** O código está lá, o caminho
nunca foi exercitado de ponta a ponta com a Meta.

---

## Ferramentas de operador (vivem fora deste repo)

`subir-midia.sh`, em `~/.claude/skills/lymphatic-by-gigi/`, chama
`emitir-url-upload` e sobe um arquivo. Fica fora do repo de propósito: tem o
project-ref de produção embutido e lê o segredo de um arquivo local com
`chmod 600`. Script apontando pra produção dentro de repo público seria um
retrocesso.

---

## Onde ficam as decisões

`PROJETO.md` é o documento mestre: posicionamento, histórico de decisões,
arquitetura de upload sem chave mestra e a lista de pendências abertas. Leia
antes de propor mudança de rumo.
