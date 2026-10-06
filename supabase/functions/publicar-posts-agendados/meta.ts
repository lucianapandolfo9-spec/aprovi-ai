// aprovi.ai — chamadas à Graph API da Meta (Instagram + Página do Facebook).
//
// Separado do index.ts em 06/10/2026 (v21) pra poder ser testado sem Deno:
// este arquivo só usa `fetch`, nada de Deno nem de supabase-js.
// Teste: supabase/verificacao/meta_publicacao.test.ts (node --test).
//
// INSTAGRAM: publicarNoInstagram é a MESMA lógica da v20 (CAROUSEL, REELS,
// IMAGE, STORIES), só movida pra cá e com a base da Graph API injetável.
//
// FACEBOOK (novo, 06/10/2026) — documentação conferida na mesma data:
//   feed foto      POST /{page}/photos (url, message)
//   carrossel      cada foto POST /{page}/photos (published=false) e depois
//                  POST /{page}/feed (message, attached_media[i]={media_fbid})
//                  🔴 o feed da Página NÃO aceita vídeo em attached_media: post
//                  carrossel com vídeo falha no FB com erro explicado (o IG sai)
//   reel/vídeo     POST /{page}/video_reels start → upload por file_url no
//                  upload_url → finish (video_state=PUBLISHED, description)
//   story foto     POST /{page}/photos (published=false) → /{page}/photo_stories
//   story vídeo    POST /{page}/video_stories start → upload → finish
//   Página exige PAGE access token: trocado a cada job a partir do token do
//   System User (GET /{page}?fields=access_token). Sem o ativo "Página"
//   atribuído ao System User na BM, essa troca falha — e o erro diz isso.
//
// 🔴 Graph API v21.0 expira em 21/01/2027 (changelog da Meta, conferido em
// 06/10/2026). Subir a versão é tarefa própria, com teste — não de carona.

export const GRAPH_PADRAO = "https://graph.facebook.com/v21.0";
const MAX_ITENS_CARROSSEL = 10; // limite da própria Meta

export type Asset = { ordem: number; tipo: "video" | "imagem"; url: string };
export type Poll = { intervalo: number; timeout: number };

export type Opcoes = {
  graph: string;
  pollVideo: Poll;
  pollImagem: Poll;
  pollVideoFb: Poll;
};

// Vídeo demora pra processar do lado da Meta; imagem fica pronta quase na hora.
// Todo timeout abaixo de ~100s: cabe no teto de ~150s da org free e falha
// LIMPO, com erro gravado (lição do job órfão de 05/10/2026).
export const OPCOES_PADRAO: Opcoes = {
  graph: GRAPH_PADRAO,
  pollVideo: { intervalo: 10_000, timeout: 100_000 },
  pollImagem: { intervalo: 2_000, timeout: 60_000 },
  // FB: só pra pegar erro imediato de processamento; se ainda estiver
  // processando no fim, o finish já foi aceito e a Meta termina sozinha.
  pollVideoFb: { intervalo: 5_000, timeout: 60_000 },
};

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// =====================================================================
// INSTAGRAM (lógica da v20)
// =====================================================================

function pollDe(asset: Asset, o: Opcoes): Poll {
  return asset.tipo === "imagem" ? o.pollImagem : o.pollVideo;
}

async function criarContainer(
  o: Opcoes,
  igUserId: string,
  token: string,
  params: Record<string, string>,
): Promise<string> {
  const body = new URLSearchParams({ ...params, access_token: token });
  const resp = await fetch(`${o.graph}/${igUserId}/media`, { method: "POST", body });
  const json = await resp.json();
  if (!resp.ok || !json.id) {
    throw new Error(`erro ao criar container: ${JSON.stringify(json)}`);
  }
  return json.id as string;
}

async function aguardarContainer(o: Opcoes, creationId: string, token: string, poll: Poll) {
  let statusCode = "IN_PROGRESS";
  const deadline = Date.now() + poll.timeout;
  while (statusCode === "IN_PROGRESS" && Date.now() < deadline) {
    await sleep(poll.intervalo);
    const resp = await fetch(
      `${o.graph}/${creationId}?fields=status_code&access_token=${encodeURIComponent(token)}`,
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

async function publicarContainer(o: Opcoes, igUserId: string, token: string, creationId: string) {
  const body = new URLSearchParams({ creation_id: creationId, access_token: token });
  const resp = await fetch(`${o.graph}/${igUserId}/media_publish`, { method: "POST", body });
  const json = await resp.json();
  if (!resp.ok || !json.id) {
    throw new Error(`erro ao publicar: ${JSON.stringify(json)}`);
  }
  return json.id as string;
}

export async function publicarNoInstagram(
  igUserId: string,
  token: string,
  caption: string,
  mediaType: string,
  assets: Asset[],
  o: Opcoes = OPCOES_PADRAO,
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
      const filho = await criarContainer(o, igUserId, token, params);
      await aguardarContainer(o, filho, token, pollDe(asset, o));
      filhos.push(filho);
    }

    // 2. container pai, que carrega a legenda
    creationId = await criarContainer(o, igUserId, token, {
      media_type: "CAROUSEL",
      children: filhos.join(","),
      caption,
    });
    await aguardarContainer(o, creationId, token, o.pollImagem);
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

    creationId = await criarContainer(o, igUserId, token, params);
    await aguardarContainer(o, creationId, token, pollDe(principal, o));
  }

  const igMediaId = await publicarContainer(o, igUserId, token, creationId);
  return { creationId, igMediaId };
}

// =====================================================================
// FACEBOOK (Página)
// =====================================================================

async function lerJson(resp: Response) {
  const texto = await resp.text();
  try {
    return JSON.parse(texto);
  } catch {
    return { _corpo_nao_json: texto.slice(0, 300) };
  }
}

async function postGraph(
  o: Opcoes,
  caminho: string,
  token: string,
  params: Record<string, string>,
  etapa: string,
) {
  const body = new URLSearchParams({ ...params, access_token: token });
  const resp = await fetch(`${o.graph}/${caminho}`, { method: "POST", body });
  const json = await lerJson(resp);
  if (!resp.ok || json.error) {
    throw new Error(`facebook ${etapa}: ${JSON.stringify(json.error ?? json)}`);
  }
  return json;
}

export async function tokenDaPagina(o: Opcoes, pageId: string, tokenSistema: string) {
  const resp = await fetch(
    `${o.graph}/${pageId}?fields=access_token&access_token=${encodeURIComponent(tokenSistema)}`,
  );
  const json = await lerJson(resp);
  if (!resp.ok || !json.access_token) {
    // nunca devolver o corpo inteiro: em caso de sucesso parcial ele traria token
    const erro = json.error ? JSON.stringify(json.error) : "resposta sem access_token";
    throw new Error(
      `facebook: o System User nao tem acesso a Pagina ${pageId} ` +
        `(atribuir a Pagina como ativo do System User na BM): ${erro}`,
    );
  }
  return json.access_token as string;
}

async function subirFotoNaoPublicada(o: Opcoes, pageId: string, token: string, url: string) {
  const json = await postGraph(o, `${pageId}/photos`, token, { url, published: "false" }, "foto nao publicada");
  if (!json.id) throw new Error(`facebook foto nao publicada sem id: ${JSON.stringify(json)}`);
  return json.id as string;
}

// Upload de vídeo hospedado: a Meta baixa o arquivo da URL pública do Storage.
async function uploadPorUrl(uploadUrl: string, token: string, fileUrl: string, etapa: string) {
  const resp = await fetch(uploadUrl, {
    method: "POST",
    headers: { Authorization: `OAuth ${token}`, file_url: fileUrl },
  });
  const json = await lerJson(resp);
  if (!resp.ok || json.error || json.success === false) {
    throw new Error(`facebook ${etapa} upload: ${JSON.stringify(json.error ?? json)}`);
  }
}

// Devolve o último status visto. Lança só se a Meta disser `error`.
async function acompanharVideoFb(o: Opcoes, videoId: string, token: string) {
  const deadline = Date.now() + o.pollVideoFb.timeout;
  let ultimo = "desconhecido";
  while (Date.now() < deadline) {
    await sleep(o.pollVideoFb.intervalo);
    const resp = await fetch(
      `${o.graph}/${videoId}?fields=status&access_token=${encodeURIComponent(token)}`,
    );
    const json = await lerJson(resp);
    const st = json?.status ?? {};
    ultimo = st.video_status ?? ultimo;
    const fases = [st.uploading_phase, st.processing_phase, st.publishing_phase];
    if (ultimo === "error" || fases.some((f: { status?: string } | undefined) => f?.status === "error")) {
      throw new Error(`facebook: processamento do video falhou: ${JSON.stringify(st)}`);
    }
    if (ultimo === "ready" || st.publishing_phase?.status === "complete") {
      return ultimo;
    }
  }
  return ultimo;
}

async function videoEmTresFases(
  o: Opcoes,
  pageId: string,
  token: string,
  aresta: "video_reels" | "video_stories",
  url: string,
  finish: Record<string, string>,
) {
  const ini = await postGraph(o, `${pageId}/${aresta}`, token, { upload_phase: "start" }, `${aresta} start`);
  if (!ini.video_id || !ini.upload_url) {
    throw new Error(`facebook ${aresta} start sem video_id/upload_url: ${JSON.stringify(ini)}`);
  }
  await uploadPorUrl(ini.upload_url, token, url, aresta);
  const fim = await postGraph(
    o,
    `${pageId}/${aresta}`,
    token,
    { video_id: String(ini.video_id), upload_phase: "finish", ...finish },
    `${aresta} finish`,
  );
  if (fim.success === false) {
    throw new Error(`facebook ${aresta} finish recusado: ${JSON.stringify(fim)}`);
  }
  return { videoId: String(ini.video_id), fim };
}

export async function publicarNoFacebook(
  pageId: string,
  tokenSistema: string,
  caption: string,
  mediaType: string,
  assets: Asset[],
  o: Opcoes = OPCOES_PADRAO,
): Promise<{ objetoId: string | null; postId: string | null }> {
  if (assets.length === 0) {
    throw new Error("post sem asset anexado");
  }
  // Checagens que não precisam de rede vêm antes da troca de token.
  if (mediaType === "CAROUSEL") {
    if (assets.some((a) => a.tipo !== "imagem")) {
      throw new Error(
        "facebook: a Pagina nao aceita carrossel com video pela API (attached_media so aceita foto). " +
          "Este canal nao publicou; o Instagram segue normal.",
      );
    }
    if (assets.length > MAX_ITENS_CARROSSEL) {
      throw new Error(`carrossel aceita no maximo ${MAX_ITENS_CARROSSEL} itens (esse post tem ${assets.length})`);
    }
  }

  const token = await tokenDaPagina(o, pageId, tokenSistema);
  const principal = assets[0];

  if (mediaType === "STORIES") {
    if (principal.tipo === "imagem") {
      const fotoId = await subirFotoNaoPublicada(o, pageId, token, principal.url);
      const r = await postGraph(o, `${pageId}/photo_stories`, token, { photo_id: fotoId }, "photo_stories");
      return { objetoId: fotoId, postId: r.post_id ?? null };
    }
    const { videoId, fim } = await videoEmTresFases(o, pageId, token, "video_stories", principal.url, {});
    return { objetoId: videoId, postId: fim.post_id ?? null };
  }

  if (mediaType === "IMAGE") {
    const r = await postGraph(o, `${pageId}/photos`, token, { url: principal.url, message: caption }, "foto");
    return { objetoId: r.id ?? null, postId: r.post_id ?? null };
  }

  if (mediaType === "CAROUSEL") {
    const params: Record<string, string> = { message: caption };
    let i = 0;
    for (const a of assets) {
      const id = await subirFotoNaoPublicada(o, pageId, token, a.url);
      params[`attached_media[${i}]`] = JSON.stringify({ media_fbid: id });
      i++;
    }
    const r = await postGraph(o, `${pageId}/feed`, token, params, "feed multi-foto");
    return { objetoId: null, postId: r.id ?? null };
  }

  // REELS (vídeo único de feed)
  const { videoId, fim } = await videoEmTresFases(o, pageId, token, "video_reels", principal.url, {
    video_state: "PUBLISHED",
    description: caption,
  });
  await acompanharVideoFb(o, videoId, token);
  return { objetoId: videoId, postId: fim.post_id ?? null };
}
