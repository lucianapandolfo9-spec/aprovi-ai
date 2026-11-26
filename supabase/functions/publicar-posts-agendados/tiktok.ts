// aprovi.ai — publicação no TikTok (Content Posting API v2). Testável sem Deno.
//
// Dois modos (contas_rede.modo):
//   rascunho → /v2/post/publish/inbox/video/init/  (video.upload: cai na caixa de entrada do
//              app, a pessoa toca em postar). Funciona sem auditoria. É a ponte (D6).
//   direto   → /v2/post/publish/video/init/        (video.publish). Sem auditoria a TikTok
//              força SELF_ONLY; com auditoria vale a privacidade escolhida pela cliente (D3).
//
// Em DUAS execuções do cron, por causa do teto de ~150 s da Edge Function:
//   fase 1 (etapa null):       baixa o vídeo do Storage, init + PUT (FILE_UPLOAD), devolve publish_id
//   fase 2 (etapa 'confirmar'): /status/fetch/ até SEND_TO_USER_INBOX ou PUBLISH_COMPLETE
//
// FILE_UPLOAD e não PULL_FROM_URL: o Storage é *.supabase.co, domínio que não dá pra verificar
// na TikTok. O bucket tem teto de 50 MB, então é sempre 1 pedaço só (TikTok aceita até 64 MB
// num pedaço; abaixo de 5 MB é obrigatório ser 1 pedaço).

export const TIKTOK_API_PADRAO = "https://open.tiktokapis.com";

export type DadosJobTiktok = {
  modo: "rascunho" | "direto";
  access_token: string;
  video_url: string;
  legenda: string | null;
  opcoes_tiktok: OpcoesTiktok | null;
};

export type OpcoesTiktok = {
  privacy_level?: string;
  disable_comment?: boolean;
  disable_duet?: boolean;
  disable_stitch?: boolean;
  brand_content_toggle?: boolean;
  brand_organic_toggle?: boolean;
};

export type ResultadoFase1 = { publishId: string };
export type ResultadoFase2 =
  | { estado: "processando" }
  | { estado: "concluido"; visibilidade: "rascunho" | "publico" | "privado"; postId: string | null }
  | { estado: "falhou"; motivo: string };

async function chamar(api: string, caminho: string, token: string, corpo: unknown) {
  const r = await fetch(`${api}${caminho}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json; charset=UTF-8" },
    body: JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  const codigo = j?.error?.code;
  if (!r.ok || (codigo && codigo !== "ok")) {
    throw new Error(`TikTok ${caminho}: ${codigo ?? r.status} ${j?.error?.message ?? ""}`.trim());
  }
  return j.data ?? {};
}

export async function renovarToken(api: string, clientKey: string, clientSecret: string, refresh: string) {
  const r = await fetch(`${api}/v2/oauth/token/`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_key: clientKey,
      client_secret: clientSecret,
      grant_type: "refresh_token",
      refresh_token: refresh,
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) {
    throw new Error(`TikTok nao renovou o token: ${j.error ?? r.status}. Reconectar a conta no painel.`);
  }
  return j as { access_token: string; expires_in: number; refresh_token: string; refresh_expires_in: number };
}

// Decide a privacidade que vai na API. Sem opção da cliente no modo direto = não publica.
export function privacidadeDireto(opcoes: OpcoesTiktok | null, permitidas: string[]): string {
  const escolhida = opcoes?.privacy_level;
  if (!escolhida) {
    throw new Error("modo direto sem privacidade escolhida pela cliente no link de aprovacao");
  }
  if (!permitidas.includes(escolhida)) {
    // conta não auditada só oferece SELF_ONLY: cai aqui e avisa, sem trocar sozinho
    throw new Error(`privacidade ${escolhida} nao permitida para esta conta (opcoes: ${permitidas.join(", ")})`);
  }
  return escolhida;
}

export async function enviarVideo(api: string, d: DadosJobTiktok): Promise<ResultadoFase1> {
  if (!d.video_url) throw new Error("post sem video para o TikTok");

  const arquivo = await fetch(d.video_url);
  if (!arquivo.ok) throw new Error(`nao baixou o video do Storage (${arquivo.status})`);
  const bytes = new Uint8Array(await arquivo.arrayBuffer());
  const tamanho = bytes.byteLength;
  if (tamanho > 64 * 1024 * 1024) throw new Error("video acima de 64 MB: recomprimir");

  const source_info = {
    source: "FILE_UPLOAD",
    video_size: tamanho,
    chunk_size: tamanho,
    total_chunk_count: 1,
  };

  let init: { publish_id?: string; upload_url?: string };
  if (d.modo === "direto") {
    const criador = await chamar(api, "/v2/post/publish/creator_info/query/", d.access_token, {});
    const privacy_level = privacidadeDireto(d.opcoes_tiktok, criador.privacy_level_options ?? []);
    const o = d.opcoes_tiktok ?? {};
    init = await chamar(api, "/v2/post/publish/video/init/", d.access_token, {
      post_info: {
        title: (d.legenda ?? "").slice(0, 2200),
        privacy_level,
        disable_comment: o.disable_comment ?? true,
        disable_duet: o.disable_duet ?? true,
        disable_stitch: o.disable_stitch ?? true,
        brand_content_toggle: o.brand_content_toggle ?? false,
        brand_organic_toggle: o.brand_organic_toggle ?? false,
      },
      source_info,
    });
  } else {
    init = await chamar(api, "/v2/post/publish/inbox/video/init/", d.access_token, { source_info });
  }

  if (!init.publish_id || !init.upload_url) throw new Error("TikTok nao devolveu publish_id/upload_url");

  const put = await fetch(init.upload_url, {
    method: "PUT",
    headers: {
      "Content-Type": "video/mp4",
      "Content-Length": String(tamanho),
      "Content-Range": `bytes 0-${tamanho - 1}/${tamanho}`,
    },
    body: bytes,
  });
  if (!put.ok) throw new Error(`upload do video para o TikTok falhou (${put.status})`);

  return { publishId: init.publish_id };
}

export async function conferirEnvio(
  api: string, token: string, publishId: string, modo: "rascunho" | "direto",
  privacidade: string | null,
): Promise<ResultadoFase2> {
  const s = await chamar(api, "/v2/post/publish/status/fetch/", token, { publish_id: publishId });
  switch (s.status) {
    case "SEND_TO_USER_INBOX":
      return { estado: "concluido", visibilidade: "rascunho", postId: null };
    case "PUBLISH_COMPLETE": {
      const ids = s.publicaly_available_post_id ?? s.publicly_available_post_id ?? [];
      const visibilidade = modo === "rascunho"
        ? "rascunho"
        : (privacidade === "PUBLIC_TO_EVERYONE" ? "publico" : "privado");
      return { estado: "concluido", visibilidade, postId: ids[0] ? String(ids[0]) : null };
    }
    case "FAILED":
      return { estado: "falhou", motivo: `TikTok recusou o video: ${s.fail_reason ?? "sem motivo"}` };
    default:
      return { estado: "processando" };
  }
}
