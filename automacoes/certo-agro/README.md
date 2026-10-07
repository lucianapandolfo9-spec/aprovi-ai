# Moldes das automações do Certo Agro

`story-cotacao-molde-1080x1920.html` — molde do story diário da cotação da @ (MG, GO, MS, SP).

O workflow n8n **"CERTO AGRO — Story de cotação (aprovi.ai)"** baixa este arquivo pelo
`raw.githubusercontent.com` (branch `main`), troca os 5 campos literais (`[MG]`, `[GO]`, `[MS]`,
`[SP]`, `[data]`) e manda o HTML pro Gotenberg da VPS renderizar em PNG 1080×1920.

Por que mora aqui e não no Storage nem num nó do n8n:
- o bucket `posta-ai-media` só aceita mp4/mov/jpg/png/webp (HTML é recusado);
- o arquivo tem ~285 KB (imagens em base64 embutidas): colado num nó do n8n vira edição frágil
  (gotcha #27 do protocolo n8n);
- aqui ele fica versionado, com diff e revisão — trocar o visual é um commit.

Regras ao editar:
- cada campo aparece **uma única vez** (o n8n faz replace simples);
- não renomear nem mover o arquivo sem atualizar a URL no workflow;
- o comentário do topo não pode conter os tokens dos campos.

Fonte do desenho: designer-criativos, 06/10/2026
(`~/Downloads/Criativos/Certo Agro/ciclo-07-20-out/story-cotacao-diaria-molde-n8n/`).
