// aprovi.ai — Edge Function `emitir-url-upload`  (11/09/2026)
//
// ⚠️ ESTE ARQUIVO FOI BAIXADO DO DEPLOY (versão 20) em 01/10/2026, não
// copiado de nenhuma cópia local. Existia uma cópia em
// ~/.claude/skills/lymphatic-by-gigi/emitir-url-upload.ts que estava
// DESATUALIZADA — ela lia `vault` e `posta_ai` direto do Deno via
// sb.schema(), arquitetura que não funciona (ver GOTCHA abaixo) e que foi
// substituída. Esta é a fonte da verdade.
//
// POR QUE EXISTE
// Ate aqui, subir midia pro Storage exigia a `service_role` key num curl local.
// Essa chave e a chave MESTRA do banco: ignora RLS em toda tabela de todos os
// clientes. Usar isso pra gravar um arquivo num bucket e desproporcional — e por
// isso o classificador de seguranca do Claude Code bloqueia (corretamente)
// qualquer Bash que a embuta. Efeito colateral: a Luciana tinha que rodar script
// a mao toda leva, E a chave mestra ficava em texto puro no disco dela.
//
// O QUE ESTA FUNCAO FAZ
// Emite uma URL de upload ASSINADA, valida por poucos minutos e escopada a UM
// caminho dentro de UM bucket. Quem chama nao recebe credencial de banco
// nenhuma — recebe uma autorizacao descartavel pra por um arquivo num lugar.
// A `service_role` fica so aqui dentro, injetada pelo runtime.
//
// Mesmo padrao ja homologado em `publicar-posts-agendados`: quem chama usa a
// anon key (publica) e a funcao guarda as credenciais reais.
//
// AUTENTICACAO: header `x-upload-secret`.
//   - Valor cru gerado no disco da Luciana, NUNCA passou por chat nem por banco.
//   - O Vault guarda so o SHA-256 dele.
//   - A comparacao acontece dentro do Postgres (rpc_validar_upload), que devolve
//     so um codigo — o hash nunca sai do banco.
//
// 🔴 GOTCHA que custou duas tentativas: os schemas `vault` E `posta_ai` NAO sao
// expostos via REST (de proposito). Entao nem `sb.schema("vault")` nem
// `sb.schema("posta_ai")` funcionam aqui — falham com "Invalid schema". Toda
// leitura desses dois tem que passar por RPC SECURITY DEFINER no schema public.
//
// Segredo estreito de proposito: se vazar, o pior caso e alguem subir arquivo no
// bucket. Nao ha acesso a tabela nenhuma.
//
// USO
//   1) POST /functions/v1/emitir-url-upload
//      headers: Authorization: Bearer <ANON_KEY>, x-upload-secret: <SEGREDO>
//      body:    {"brand_id": "...", "nome_arquivo": "ad6.mp4"}
//   2) PUT <signed_url> com o arquivo (nenhuma credencial nesse passo)

import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "posta-ai-media";

// So o que o aprovi.ai realmente publica. Extensao fora da lista e recusada
// antes de emitir qualquer URL — a funcao nunca vira upload generico.
const TIPOS: Record<string, string> = {
  mp4: "video/mp4",
  mov: "video/quicktime",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
};

async function sha256Hex(texto: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(texto),
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function json(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { erro: "use POST" });

  let corpo: { brand_id?: string; nome_arquivo?: string };
  try {
    corpo = await req.json();
  } catch {
    return json(400, { erro: "json invalido" });
  }

  const { brand_id, nome_arquivo } = corpo ?? {};
  if (!brand_id || !nome_arquivo) {
    return json(400, { erro: "brand_id e nome_arquivo sao obrigatorios" });
  }

  const ext = String(nome_arquivo).split(".").pop()?.toLowerCase() ?? "";
  if (!(ext in TIPOS)) {
    return json(400, { erro: `extensao nao permitida: .${ext}` });
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const enviado = req.headers.get("x-upload-secret") ?? "";
  const { data: veredito, error: eValida } = await sb.rpc(
    "rpc_validar_upload",
    { p_hash: await sha256Hex(enviado), p_brand_id: brand_id },
  );

  if (eValida) return json(500, { erro: eValida.message });
  if (veredito === "nao_autorizado") return json(401, { erro: "nao autorizado" });
  if (veredito === "marca_inexistente") {
    return json(404, { erro: "brand_id nao existe" });
  }
  if (veredito !== "ok") return json(500, { erro: "validacao inesperada" });

  const slug = String(nome_arquivo)
    .toLowerCase()
    .replace(/[^a-z0-9.\-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  // Mesmo formato de path que o painel e os scripts antigos ja usavam.
  const path = `${brand_id}/${Math.floor(Date.now() / 1000)}-0-${slug}`;

  const { data, error } = await sb.storage
    .from(BUCKET)
    .createSignedUploadUrl(path);

  if (error) return json(500, { erro: error.message });

  return json(200, {
    path,
    signed_url: data.signedUrl,
    token: data.token,
    content_type: TIPOS[ext],
    public_url:
      `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/${BUCKET}/${path}`,
  });
});
