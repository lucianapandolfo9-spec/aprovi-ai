// aprovi.ai — Edge Function `limpar-midia-publicada` (06/10/2026)
//
// Decisão 10 do grill de 06/10/2026: apagar do Storage a mídia de post
// publicado há 30+ dias (org free, bucket com teto de 1 GB). Exceção
// decidida pela Luciana no mesmo dia: mídia de marca com rodízio de story
// ativo (Gigi) fica, porque ainda alimenta o rodízio.
//
// POR QUE EDGE FUNCTION E NÃO SQL: apagar a linha de storage.objects não
// libera os bytes (aprendido em 01/10/2026). Só a Storage API apaga de
// verdade, e ela exige service_role — que aqui é injetada pelo runtime e
// nunca passa por terminal nem por chat.
//
// Quem decide O QUE apagar é o banco (rpc_midia_expirada, com piso de 30
// dias que ninguém fura). Esta função só executa a lista.
//
// MODOS (body JSON):
//   {"modo":"listar"}  → padrão. Só devolve a lista e o total. Não apaga nada.
//                        É o que roda na 1ª vez, pra Luciana ver antes.
//   {"modo":"apagar"}  → apaga do bucket e marca post_assets.midia_removida_em.
//                        Até MAX_POR_EXECUCAO arquivos por chamada.
//   "dias" opcional (>= 30; abaixo disso o banco recusa).
//
// verify_jwt = true (config.toml): o pg_cron chama com a anon key, como o
// publicador. Risco aceito e registrado: quem tem a anon key (pública) pode
// disparar a limpeza — mas só do que a regra de 30 dias já mandaria apagar.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const BUCKET = "posta-ai-media";
const MAX_POR_EXECUCAO = 200;
const LOTE_REMOCAO = 100;

type Item = {
  url: string;
  caminho: string;
  bytes: number | null;
  brand_id: string;
  publicado_em: string;
  existe_no_storage: boolean;
};

function json(status: number, corpo: unknown) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  let corpo: { modo?: string; dias?: number } = {};
  try {
    corpo = await req.json();
  } catch {
    corpo = {};
  }
  const modo = corpo.modo === "apagar" ? "apagar" : "listar";
  const dias = Number.isFinite(corpo.dias) ? Number(corpo.dias) : 30;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data, error } = await sb.rpc("rpc_midia_expirada", { p_dias: dias });
  if (error) return json(400, { erro: error.message });

  const itens = (data ?? []) as Item[];
  const totalBytes = itens.reduce((s, i) => s + (i.bytes ?? 0), 0);

  if (modo === "listar") {
    return json(200, {
      modo,
      dias,
      arquivos: itens.length,
      mb: Math.round((totalBytes / 1024 / 1024) * 10) / 10,
      itens,
    });
  }

  const alvo = itens.slice(0, MAX_POR_EXECUCAO);
  const existentes = alvo.filter((i) => i.existe_no_storage);
  // URL cujo arquivo já não existe no bucket: só marca (sem chamar a API)
  const marcar: string[] = alvo.filter((i) => !i.existe_no_storage).map((i) => i.url);
  const falhas: unknown[] = [];

  for (let k = 0; k < existentes.length; k += LOTE_REMOCAO) {
    const lote = existentes.slice(k, k + LOTE_REMOCAO);
    const { data: removidos, error: eRm } = await sb.storage.from(BUCKET).remove(lote.map((i) => i.caminho));
    if (eRm) {
      falhas.push({ lote: k / LOTE_REMOCAO, erro: eRm.message });
      continue;
    }
    // só marca o que a API confirmou que removeu
    const nomes = new Set((removidos ?? []).map((o: { name: string }) => o.name));
    for (const i of lote) {
      if (nomes.has(i.caminho)) marcar.push(i.url);
      else falhas.push({ caminho: i.caminho, erro: "nao confirmado pela Storage API" });
    }
  }

  let marcados = 0;
  if (marcar.length > 0) {
    const { data: n, error: eMk } = await sb.rpc("rpc_marcar_midia_removida", { p_urls: marcar });
    if (eMk) falhas.push({ etapa: "marcar", erro: eMk.message });
    else marcados = n as number;
  }

  return json(200, {
    modo,
    dias,
    elegiveis: itens.length,
    processados: alvo.length,
    apagados_do_bucket: marcar.length - alvo.filter((i) => !i.existe_no_storage).length,
    mb_liberados_estimado: Math.round(
      (existentes.filter((i) => marcar.includes(i.url)).reduce((s, i) => s + (i.bytes ?? 0), 0) / 1024 / 1024) * 10,
    ) / 10,
    marcados,
    falhas,
    restam: Math.max(0, itens.length - alvo.length),
  });
});
