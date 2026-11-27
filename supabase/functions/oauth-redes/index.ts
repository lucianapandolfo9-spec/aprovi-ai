// aprovi.ai — conexão de contas por OAuth (TikTok; YouTube entra no mesmo molde).
//
// Fluxo:
//   1. Painel (admin logado) chama posta_ai_admin_iniciar_conexao(brand, rede) → state de uso único.
//   2. Painel chama esta função com {acao:"url", rede, state} → URL de autorização da rede.
//   3. A rede devolve para https://luhpanda.online/conectar.html?code=…&state=…
//   4. conectar.html chama esta função com {acao:"concluir", rede, code, state}.
//   5. Aqui: troca o code por token, lê o perfil e grava via rpc_concluir_conexao_rede
//      (que consome o state e guarda os tokens no Vault). Token nunca volta pro navegador.
//
// Autorização: o state (24 bytes aleatórios, 15 min, uso único, criado só por admin).
// verify_jwt=true: o front manda a anon key, só para passar o portão.
//
// Segredos (Edge Functions → Secrets): TIKTOK_CLIENT_KEY, TIKTOK_CLIENT_SECRET.
// TIKTOK_API_BASE / TIKTOK_AUTH_BASE só para teste local com mock.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const REDIRECT_URI = "https://luhpanda.online/conectar.html";
const TIKTOK_ESCOPOS = ["user.info.basic", "video.upload", "video.publish"];
const TIKTOK_AUTH = Deno.env.get("TIKTOK_AUTH_BASE") || "https://www.tiktok.com";
const TIKTOK_API = Deno.env.get("TIKTOK_API_BASE") || "https://open.tiktokapis.com";

const ORIGENS = ["https://luhpanda.online", "http://localhost:8000", "http://127.0.0.1:8000"];

function cors(req: Request) {
  const origem = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGENS.includes(origem) ? origem : ORIGENS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function resposta(req: Request, corpo: unknown, status = 200) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...cors(req), "Content-Type": "application/json" },
  });
}

async function tiktokTrocarCodigo(code: string) {
  const r = await fetch(`${TIKTOK_API}/v2/oauth/token/`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_key: Deno.env.get("TIKTOK_CLIENT_KEY")!,
      client_secret: Deno.env.get("TIKTOK_CLIENT_SECRET")!,
      code,
      grant_type: "authorization_code",
      redirect_uri: REDIRECT_URI,
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) {
    // nunca devolve o corpo inteiro (pode ter token): só o erro
    throw new Error(`TikTok recusou o código: ${j.error ?? r.status} ${j.error_description ?? ""}`.trim());
  }
  return j as {
    access_token: string; expires_in: number; open_id: string;
    refresh_token: string; refresh_expires_in: number; scope: string;
  };
}

async function tiktokPerfil(accessToken: string) {
  const r = await fetch(`${TIKTOK_API}/v2/user/info/?fields=open_id,display_name,avatar_url`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const j = await r.json().catch(() => ({}));
  const u = j?.data?.user ?? {};
  return { apelido: u.display_name ?? null, avatar: u.avatar_url ?? null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return resposta(req, { erro: "metodo" }, 405);

  let corpo: { acao?: string; rede?: string; state?: string; code?: string };
  try {
    corpo = await req.json();
  } catch {
    return resposta(req, { erro: "json invalido" }, 400);
  }
  const { acao, rede, state, code } = corpo;

  if (rede !== "tiktok") return resposta(req, { erro: "rede ainda nao suportada" }, 400);
  if (!state || !/^[0-9a-f]{48}$/.test(state)) return resposta(req, { erro: "state invalido" }, 400);
  if (!Deno.env.get("TIKTOK_CLIENT_KEY") || !Deno.env.get("TIKTOK_CLIENT_SECRET")) {
    return resposta(req, { erro: "segredos do TikTok nao configurados no Supabase" }, 500);
  }

  if (acao === "url") {
    const u = new URL(`${TIKTOK_AUTH}/v2/auth/authorize/`);
    u.searchParams.set("client_key", Deno.env.get("TIKTOK_CLIENT_KEY")!);
    u.searchParams.set("scope", TIKTOK_ESCOPOS.join(","));
    u.searchParams.set("response_type", "code");
    u.searchParams.set("redirect_uri", REDIRECT_URI);
    u.searchParams.set("state", state);
    return resposta(req, { url: u.toString() });
  }

  if (acao === "concluir") {
    if (!code) return resposta(req, { erro: "code ausente" }, 400);
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    try {
      const t = await tiktokTrocarCodigo(code);
      const p = await tiktokPerfil(t.access_token);
      const agora = Date.now();
      const { data, error } = await supabase.rpc("rpc_concluir_conexao_rede", {
        p_state: state,
        p_rede: "tiktok",
        p_conta_externa_id: t.open_id,
        p_apelido: p.apelido,
        p_avatar_url: p.avatar,
        p_access_token: t.access_token,
        p_refresh_token: t.refresh_token,
        p_expira_em: new Date(agora + t.expires_in * 1000).toISOString(),
        p_refresh_expira_em: new Date(agora + t.refresh_expires_in * 1000).toISOString(),
        p_escopos: (t.scope ?? "").split(",").filter(Boolean),
      });
      if (error) return resposta(req, { erro: error.message }, 400);
      return resposta(req, { ok: true, conta: data });
    } catch (e) {
      return resposta(req, { erro: String(e instanceof Error ? e.message : e) }, 400);
    }
  }

  return resposta(req, { erro: "acao invalida" }, 400);
});
