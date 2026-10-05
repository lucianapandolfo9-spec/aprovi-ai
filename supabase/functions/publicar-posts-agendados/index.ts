// Fase 2 do aprovi.ai — publicação automática no Instagram.
//
// ⚠️ Base: deploy v19 (baixado 01/10/2026 e reconferido 05/10/2026 contra produção).
// 05/10/2026: MAX_POSTS_POR_EXECUCAO 5→1 e POLL_VIDEO.timeout 5min→100s (job órfão).
// Originalmente BAIXADO DO DEPLOY (versão 19) em 01/10/2026, não
// copiado de nenhuma cópia local. Existia uma cópia em
// ~/.claude/skills/lymphatic-by-gigi/publicar-posts-agendados.ts que estava
// DESATUALIZADA — sem suporte a CAROUSEL, STORIES nem `children`, que
// entraram em 10/set. Esta é a fonte da verdade.
//
// Roda a cada 10 min (pg_cron + pg_net). Em cada execução:
//   1. Chama rpc_proximo_post_agendado() — lock atômico, decripta o token do
//      Vault, monta a legenda final (corpo + assinatura) e devolve TODOS os
//      assets do post em `assets` (jsonb ordenado por `ordem`).
//   2. Publica de verdade via Instagram Content Publishing API.
//   3. Grava o resultado via rpc_marcar_resultado_publicacao().
//   4. Repete até a fila secar.
//
// Formatos suportados (media_type vem pronto da RPC):
//   REELS    — vídeo único no feed
//   IMAGE    — foto única no feed
//   CAROUSEL — 2 a 10 itens, foto e/ou vídeo misturados
//   STORIES  — vídeo ou foto único; a Meta ignora caption em story, então
//              o parâmetro nem é enviado nesse caso.
//
// Claude nunca dispara isso manualmente fora de teste controlado — o gatilho
// real é `agendado_para` vencer num post já `agendado`.
//
// 🔴 A CREDENCIAL: esta função usa SUPABASE_SERVICE_ROLE_KEY, injetada pelo
// runtime. É por isso que ela consegue chamar rpc_proximo_post_agendado e
// rpc_marcar_resultado_publicacao, que são service_role-only. Nunca troque
// por anon key "pra simplificar" — as duas RPCs param de responder.
//
// 📌 Note que um erro de RPC NÃO vira HTTP != 200: o erro entra em
// `resultados` e a resposta continua 200. Logo, status 200 no log do gateway
// não prova que publicou. Pra saber de verdade, olhe posta_ai.publish_jobs.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const GRAPH_API_VERSION = "v21.0";
const GRAPH_BASE = `https://graph.facebook.com/${GRAPH_API_VERSION}`;
// 1 por execução (era 5 até 05/10/2026). A org é free → teto de wall-clock ~150s.
// Com 5 em série, o 2º vídeo da mesma execução estourava o teto e a function era
// morta no meio do poll, deixando job órfão em `em_andamento` (Organic2, 18/09).
// O próximo item sai no cron seguinte (+10 min).
const MAX_POSTS_POR_EXECUCAO = 1;
const MAX_ITENS_CARROSSEL = 10;   // limite da própria Meta

// Vídeo demora pra processar do lado da Meta; imagem fica pronta quase na hora.
// timeout 100s (era 5 min): tem que caber no teto da plataforma pra falhar LIMPO,
// com erro gravado em publish_jobs, em vez de ser morto calado.
const POLL_VIDEO = { intervalo: 10_000, timeout: 100_000 };
const POLL_IMAGEM = { intervalo: 2_000, timeout: 60 * 1000 };

type Asset = { ordem: number; tipo: "video" | "imagem"; url: string };
type Poll = { intervalo: number; timeout: number };

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pollDe(asset: Asset): Poll {
  return asset.tipo === "imagem" ? POLL_IMAGEM : POLL_VIDEO;
}

async function criarContainer(
  igUserId: string,
  token: string,
  params: Record<string, string>,
): Promise<string> {
  const body = new URLSearchParams({ ...params, access_token: token });
  const resp = await fetch(`${GRAPH_BASE}/${igUserId}/media`, { method: "POST", body });
  const json = await resp.json();
  if (!resp.ok || !json.id) {
    throw new Error(`erro ao criar container: ${JSON.stringify(json)}`);
  }
  return json.id as string;
}

async function aguardarContainer(creationId: string, token: string, poll: Poll) {
  let statusCode = "IN_PROGRESS";
  const deadline = Date.now() + poll.timeout;
  while (statusCode === "IN_PROGRESS" && Date.now() < deadline) {
    await sleep(poll.intervalo);
    const resp = await fetch(
      `${GRAPH_BASE}/${creationId}?fields=status_code&access_token=${encodeURIComponent(token)}`,
    );
    const json = await resp.json();
    statusCode = json.status_code ?? "ERROR";
    if (statusCode === "ERROR") {
      throw new Error(`processamento falhou do lado da Meta: ${JSON.stringify(json)}`);
    }
  }
  if (statusCode !== "FINISHED") {
    throw new Error(`timeout esperando o container processar (status: ${statusCode})`);
  }
}

async function publicarContainer(igUserId: string, token: string, creationId: string) {
  const body = new URLSearchParams({ creation_id: creationId, access_token: token });
  const resp = await fetch(`${GRAPH_BASE}/${igUserId}/media_publish`, { method: "POST", body });
  const json = await resp.json();
  if (!resp.ok || !json.id) {
    throw new Error(`erro ao publicar: ${JSON.stringify(json)}`);
  }
  return json.id as string;
}

async function publicarNoInstagram(
  igUserId: string,
  token: string,
  caption: string,
  mediaType: string,
  assets: Asset[],
) {
  if (assets.length === 0) {
    throw new Error("post sem asset anexado");
  }

  let creationId: string;

  if (mediaType === "CAROUSEL") {
    if (assets.length < 2) {
      throw new Error("carrossel precisa de pelo menos 2 itens");
    }
    if (assets.length > MAX_ITENS_CARROSSEL) {
      throw new Error(
        `carrossel aceita no maximo ${MAX_ITENS_CARROSSEL} itens (esse post tem ${assets.length})`,
      );
    }

    // 1. um container filho por item, na ordem definida em post_assets.ordem
    const filhos: string[] = [];
    for (const asset of assets) {
      const params: Record<string, string> = { is_carousel_item: "true" };
      if (asset.tipo === "imagem") {
        params.image_url = asset.url;
      } else {
        params.video_url = asset.url;
        params.media_type = "VIDEO";
      }
      const filho = await criarContainer(igUserId, token, params);
      await aguardarContainer(filho, token, pollDe(asset));
      filhos.push(filho);
    }

    // 2. container pai, que carrega a legenda
    creationId = await criarContainer(igUserId, token, {
      media_type: "CAROUSEL",
      children: filhos.join(","),
      caption,
    });
    await aguardarContainer(creationId, token, POLL_IMAGEM);
  } else {
    const principal = assets[0];
    const params: Record<string, string> = {};

    if (principal.tipo === "imagem") {
      params.image_url = principal.url;
    } else {
      params.video_url = principal.url;
    }

    // IMAGE é o default da Meta pra foto de feed — só REELS/STORIES precisam ser declarados
    if (mediaType === "REELS" || mediaType === "STORIES") {
      params.media_type = mediaType;
    }

    // Stories não exibem legenda via API — mandar seria ignorado silenciosamente
    if (mediaType !== "STORIES") {
      params.caption = caption;
    }

    creationId = await criarContainer(igUserId, token, params);
    await aguardarContainer(creationId, token, pollDe(principal));
  }

  const igMediaId = await publicarContainer(igUserId, token, creationId);
  return { creationId, igMediaId };
}

Deno.serve(async (_req) => {
  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const resultados: unknown[] = [];

  for (let i = 0; i < MAX_POSTS_POR_EXECUCAO; i++) {
    const { data, error } = await supabase.rpc("rpc_proximo_post_agendado");
    if (error) {
      resultados.push({ erro: `rpc_proximo_post_agendado falhou: ${error.message}` });
      break;
    }

    const linha = Array.isArray(data) ? data[0] : data;
    if (!linha || !linha.post_id) {
      break; // fila seca, nada mais a fazer nessa execução
    }

    const { job_id, post_id, ig_user_id, token, video_url, caption, media_type } = linha;

    // `assets` chega como jsonb; aceita array já parseado ou string.
    let assets: Asset[] = [];
    try {
      assets = Array.isArray(linha.assets)
        ? linha.assets
        : JSON.parse(linha.assets ?? "[]");
    } catch {
      assets = [];
    }
    // rede de segurança: RPC antiga/registro legado que só tenha video_url
    if (assets.length === 0 && video_url) {
      assets = [{ ordem: 0, tipo: "video", url: video_url }];
    }

    try {
      const { creationId, igMediaId } = await publicarNoInstagram(
        ig_user_id,
        token,
        caption,
        media_type,
        assets,
      );

      await supabase.rpc("rpc_marcar_resultado_publicacao", {
        p_job_id: job_id,
        p_post_id: post_id,
        p_sucesso: true,
        p_ig_creation_id: creationId,
        p_ig_media_id: igMediaId,
      });

      resultados.push({ post_id, media_type, itens: assets.length, status: "publicado", ig_media_id: igMediaId });
    } catch (e) {
      await supabase.rpc("rpc_marcar_resultado_publicacao", {
        p_job_id: job_id,
        p_post_id: post_id,
        p_sucesso: false,
        p_erro: String(e),
      });

      resultados.push({ post_id, media_type, status: "falhou", erro: String(e) });
    }
  }

  return new Response(JSON.stringify({ processados: resultados.length, resultados }), {
    headers: { "Content-Type": "application/json" },
    status: 200,
  });
});
