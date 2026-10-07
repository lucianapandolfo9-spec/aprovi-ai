// aprovi.ai — publicação automática (Instagram + Página do Facebook).
//
// v21 (06/10/2026, fase "Certo Agro no aprovi.ai"): passa a publicar POR
// CANAL. Cada post vira um lote de jobs em posta_ai.publish_jobs, um por
// canal ligado na marca (social_accounts.publicar_instagram / _facebook).
// Gigi e Luh Panda continuam só Instagram; o Certo Agro sai nos dois.
//   - fila:      rpc_proximo_job_publicacao()  (devolve UM job: um canal)
//   - resultado: rpc_marcar_resultado_job()    (fecha o post quando o lote acaba)
// As RPCs da v20 (rpc_proximo_post_agendado / rpc_marcar_resultado_publicacao)
// continuam no banco, intactas, mas esta versão não as usa.
//
// Histórico: v19 baixada do deploy em 01/10/2026 · v20 em 05/10/2026
// (1 post por execução, poll 100s — job órfão do Organic2).
//
// Roda a cada 10 min (pg_cron jobid 1 + pg_net). UM job por execução: o 2º
// canal do mesmo post sai no cron seguinte (+10 min). É isso que mantém a
// execução longe do teto de ~150s de wall-clock da org free, que mata a
// função sem passar pelo `catch` (o ceifador, cron jobid 3, cobre o resto).
//
// A lógica da Graph API mora em ./meta.ts (testável sem Deno).
//
// 🔴 A CREDENCIAL: usa SUPABASE_SERVICE_ROLE_KEY, injetada pelo runtime. As
// duas RPCs são service_role-only. Nunca troque por anon key.
//
// 📌 Erro de RPC NÃO vira HTTP != 200: entra em `resultados` e a resposta
// continua 200. Pra saber se publicou, olhe posta_ai.publish_jobs.
//
// META_GRAPH_BASE: só pra teste local (aponta pra um mock da Graph API).
// Em produção NÃO existe e vale https://graph.facebook.com/v21.0.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import {
  type Asset,
  OPCOES_PADRAO,
  type Opcoes,
  publicarNoFacebook,
  publicarNoInstagram,
} from "./meta.ts";

const MAX_JOBS_POR_EXECUCAO = 1;

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const opcoes: Opcoes = {
  ...OPCOES_PADRAO,
  graph: Deno.env.get("META_GRAPH_BASE") || OPCOES_PADRAO.graph,
};

Deno.serve(async (_req) => {
  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const resultados: unknown[] = [];

  for (let i = 0; i < MAX_JOBS_POR_EXECUCAO; i++) {
    const { data, error } = await supabase.rpc("rpc_proximo_job_publicacao");
    if (error) {
      resultados.push({ erro: `rpc_proximo_job_publicacao falhou: ${error.message}` });
      break;
    }

    const linha = Array.isArray(data) ? data[0] : data;
    if (!linha || !linha.job_id) {
      break; // fila seca (ou o post falhou na validação e já foi gravado)
    }

    const { job_id, post_id, canal, conta_id, token, caption, media_type } = linha;

    let assets: Asset[] = [];
    try {
      assets = Array.isArray(linha.assets) ? linha.assets : JSON.parse(linha.assets ?? "[]");
    } catch {
      assets = [];
    }

    let marcado;
    try {
      if (canal === "facebook") {
        const r = await publicarNoFacebook(conta_id, token, caption ?? "", media_type, assets, opcoes);
        marcado = await supabase.rpc("rpc_marcar_resultado_job", {
          p_job_id: job_id,
          p_sucesso: true,
          p_fb_objeto_id: r.objetoId,
          p_fb_post_id: r.postId,
        });
        resultados.push({ post_id, canal, media_type, status: "publicado", fb_post_id: r.postId });
      } else {
        const r = await publicarNoInstagram(conta_id, token, caption ?? "", media_type, assets, opcoes);
        marcado = await supabase.rpc("rpc_marcar_resultado_job", {
          p_job_id: job_id,
          p_sucesso: true,
          p_ig_creation_id: r.creationId,
          p_ig_media_id: r.igMediaId,
        });
        resultados.push({ post_id, canal, media_type, status: "publicado", ig_media_id: r.igMediaId });
      }
    } catch (e) {
      marcado = await supabase.rpc("rpc_marcar_resultado_job", {
        p_job_id: job_id,
        p_sucesso: false,
        p_erro: String(e),
      });
      resultados.push({ post_id, canal, media_type, status: "falhou", erro: String(e) });
    }

    if (marcado?.error) {
      resultados.push({ post_id, canal, erro: `rpc_marcar_resultado_job falhou: ${marcado.error.message}` });
    } else {
      resultados.push({ post_id, post_status: marcado?.data });
    }
  }

  return new Response(JSON.stringify({ processados: resultados.length, resultados }), {
    headers: { "Content-Type": "application/json" },
    status: 200,
  });
});
