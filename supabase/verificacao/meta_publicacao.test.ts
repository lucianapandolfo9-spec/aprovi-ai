// aprovi.ai — testes da camada Graph API (meta.ts), sem rede e sem Deno.
//   node --test supabase/verificacao/meta_publicacao.test.ts
// (Node 23.6+ roda TypeScript direto.)
//
// fetch é substituído por um mock que grava cada chamada. O token nunca é
// gravado no log (só "<token>").
//
// ORÁCULO DO INSTAGRAM: a v20 é extraída do git (commit 75a913a, main de
// 05/10/2026) e roda contra o MESMO mock. A sequência de chamadas da v21 tem
// que ser idêntica — a mudança de canal não pode alterar o Instagram.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publicarNoFacebook, publicarNoInstagram, type Opcoes } from "../functions/publicar-posts-agendados/meta.ts";

const G = "https://graph.test/v21.0";
const O: Opcoes = {
  graph: G,
  pollVideo: { intervalo: 1, timeout: 200 },
  pollImagem: { intervalo: 1, timeout: 200 },
  pollVideoFb: { intervalo: 1, timeout: 50 },
};

type Chamada = { m: string; u: string; p: Record<string, string>; h: Record<string, string> };
let log: Chamada[] = [];
let respostas: (c: Chamada) => unknown = () => ({});

function limpa(u: string) {
  return u.replace(/access_token=[^&]*/g, "access_token=<token>");
}

globalThis.fetch = (async (input: string | URL, init?: RequestInit) => {
  const u = limpa(String(input));
  const p: Record<string, string> = {};
  if (init?.body instanceof URLSearchParams) {
    for (const [k, v] of init.body) p[k] = k === "access_token" ? "<token>" : v;
  }
  const h: Record<string, string> = {};
  for (const [k, v] of Object.entries((init?.headers as Record<string, string>) ?? {})) {
    h[k] = k.toLowerCase() === "authorization" ? "<token>" : v;
  }
  const c = { m: init?.method ?? "GET", u, p, h };
  log.push(c);
  const corpo = respostas(c) as { _status?: number };
  return new Response(JSON.stringify(corpo), { status: corpo?._status ?? 200 });
}) as typeof fetch;

// Respostas padrão de uma Meta que aceita tudo
function metaFeliz(c: Chamada): unknown {
  if (c.u.includes("?fields=access_token")) return { access_token: "PAGE_TOKEN", id: "PAGE" };
  if (c.u.includes("?fields=status_code")) return { status_code: "FINISHED" };
  if (c.u.includes("?fields=status")) return { status: { video_status: "ready" } };
  if (c.u.endsWith("/media")) return { id: "CONT" + log.length };
  if (c.u.endsWith("/media_publish")) return { id: "MEDIA1" };
  if (c.u.endsWith("/photos") && c.p.published === "false") return { id: "FOTO" + log.length };
  if (c.u.endsWith("/photos")) return { id: "FOTO1", post_id: "PAGE_POST1" };
  if (c.u.endsWith("/photo_stories")) return { success: true, post_id: "STORY1" };
  if (c.u.endsWith("/feed")) return { id: "PAGE_FEED1" };
  if (c.u.endsWith("/video_reels") || c.u.endsWith("/video_stories")) {
    return c.p.upload_phase === "start"
      ? { video_id: "VID1", upload_url: "https://rupload.test/video-upload/v21.0/VID1" }
      : { success: true, post_id: "VPOST1" };
  }
  if (c.u.startsWith("https://rupload.test")) return { success: true };
  return { error: { message: "rota inesperada no mock: " + c.u } };
}

const IMG = (n: number) => ({ ordem: n, tipo: "imagem" as const, url: `https://s.test/i${n}.png` });
const VID = (n: number) => ({ ordem: n, tipo: "video" as const, url: `https://s.test/v${n}.mp4` });

// ---------------- oráculo v20 ----------------
async function carregarV20() {
  const fonte = execFileSync("git", ["show", "75a913a:supabase/functions/publicar-posts-agendados/index.ts"], {
    encoding: "utf8",
  });
  let corpo = fonte.slice(fonte.indexOf("const GRAPH_API_VERSION"), fonte.indexOf("Deno.serve("));
  corpo = corpo
    .replace(/const supabaseUrl = .*\n/, "")
    .replace(/const serviceRoleKey = .*\n/, "")
    .replace("const GRAPH_BASE = `https://graph.facebook.com/${GRAPH_API_VERSION}`;", `const GRAPH_BASE = "${G}";`)
    .replace("{ intervalo: 10_000, timeout: 100_000 }", "{ intervalo: 1, timeout: 200 }")
    .replace("{ intervalo: 2_000, timeout: 60 * 1000 }", "{ intervalo: 1, timeout: 200 }");
  const dir = mkdtempSync(join(tmpdir(), "v20-"));
  const arq = join(dir, "v20.ts");
  writeFileSync(arq, corpo + "\nexport { publicarNoInstagram };\n");
  return (await import(arq)).publicarNoInstagram as (
    ig: string, t: string, c: string, m: string, a: unknown[],
  ) => Promise<{ creationId: string; igMediaId: string }>;
}

for (const [nome, mt, assets] of [
  ["REELS", "REELS", [VID(0)]],
  ["IMAGE", "IMAGE", [IMG(0)]],
  ["STORIES imagem", "STORIES", [IMG(0)]],
  ["STORIES video", "STORIES", [VID(0)]],
  ["CAROUSEL misto", "CAROUSEL", [IMG(0), VID(1), IMG(2)]],
] as const) {
  test(`instagram ${nome}: v21 faz exatamente as chamadas da v20`, async () => {
    const v20 = await carregarV20();
    respostas = metaFeliz;
    log = [];
    const a = await v20("IG1", "tok", "legenda", mt, [...assets]);
    const logV20 = log;
    log = [];
    const b = await publicarNoInstagram("IG1", "tok", "legenda", mt, [...assets], O);
    assert.deepEqual(log, logV20);
    assert.deepEqual(b, a);
  });
}

test("instagram: erro da Meta continua virando exceção (v20 == v21)", async () => {
  const v20 = await carregarV20();
  respostas = (c) => (c.u.endsWith("/media") ? { error: { message: "nope" }, _status: 400 } : metaFeliz(c));
  await assert.rejects(v20("IG1", "tok", "x", "IMAGE", [IMG(0)]), /erro ao criar container/);
  await assert.rejects(publicarNoInstagram("IG1", "tok", "x", "IMAGE", [IMG(0)], O), /erro ao criar container/);
});

// ---------------- facebook ----------------
test("facebook IMAGE: troca token da Página e publica foto com legenda", async () => {
  respostas = metaFeliz;
  log = [];
  const r = await publicarNoFacebook("PAGE", "tok", "legenda fb", "IMAGE", [IMG(0)], O);
  assert.deepEqual(r, { objetoId: "FOTO1", postId: "PAGE_POST1" });
  assert.equal(log[0].u, `${G}/PAGE?fields=access_token&access_token=<token>`);
  assert.deepEqual(log[1], { m: "POST", u: `${G}/PAGE/photos`, p: { url: "https://s.test/i0.png", message: "legenda fb", access_token: "<token>" }, h: {} });
  assert.equal(log.length, 2);
});

test("facebook STORIES imagem: foto não publicada + photo_stories", async () => {
  respostas = metaFeliz;
  log = [];
  const r = await publicarNoFacebook("PAGE", "tok", "ignorada", "STORIES", [IMG(0)], O);
  assert.equal(r.postId, "STORY1");
  assert.deepEqual(log.map((c) => c.u.replace(G, "")), ["/PAGE?fields=access_token&access_token=<token>", "/PAGE/photos", "/PAGE/photo_stories"]);
  assert.equal(log[1].p.published, "false");
  assert.equal(log[2].p.photo_id, r.objetoId);
  assert.ok(!("message" in log[1].p), "story não leva legenda");
});

test("facebook STORIES vídeo: start → upload por file_url → finish", async () => {
  respostas = metaFeliz;
  log = [];
  const r = await publicarNoFacebook("PAGE", "tok", "x", "STORIES", [VID(0)], O);
  assert.deepEqual(r, { objetoId: "VID1", postId: "VPOST1" });
  assert.equal(log[1].p.upload_phase, "start");
  assert.equal(log[2].u, "https://rupload.test/video-upload/v21.0/VID1");
  assert.equal(log[2].h.file_url, "https://s.test/v0.mp4");
  assert.equal(log[2].h.Authorization, "<token>");
  assert.deepEqual(log[3].p, { video_id: "VID1", upload_phase: "finish", access_token: "<token>" });
});

test("facebook REELS: finish com PUBLISHED + description e acompanha status", async () => {
  respostas = metaFeliz;
  log = [];
  const r = await publicarNoFacebook("PAGE", "tok", "legenda reel", "REELS", [VID(0)], O);
  assert.equal(r.objetoId, "VID1");
  const fin = log.find((c) => c.p.upload_phase === "finish")!;
  assert.equal(fin.u, `${G}/PAGE/video_reels`);
  assert.equal(fin.p.video_state, "PUBLISHED");
  assert.equal(fin.p.description, "legenda reel");
  assert.ok(log.some((c) => c.u.includes("VID1?fields=status")));
});

test("facebook REELS: Meta diz error no processamento → exceção", async () => {
  respostas = (c) => (c.u.includes("?fields=status") ? { status: { video_status: "error" } } : metaFeliz(c));
  await assert.rejects(publicarNoFacebook("PAGE", "tok", "x", "REELS", [VID(0)], O), /processamento do video falhou/);
});

test("facebook REELS: ainda processando no fim do poll → sucesso (finish já aceito)", async () => {
  respostas = (c) => (c.u.includes("?fields=status") ? { status: { video_status: "processing" } } : metaFeliz(c));
  const r = await publicarNoFacebook("PAGE", "tok", "x", "REELS", [VID(0)], O);
  assert.equal(r.objetoId, "VID1");
});

test("facebook CAROUSEL só foto: N fotos não publicadas + feed com attached_media na ordem", async () => {
  respostas = metaFeliz;
  log = [];
  const r = await publicarNoFacebook("PAGE", "tok", "leg", "CAROUSEL", [IMG(0), IMG(1), IMG(2)], O);
  assert.equal(r.postId, "PAGE_FEED1");
  const fotos = log.filter((c) => c.u.endsWith("/photos"));
  assert.deepEqual(fotos.map((c) => c.p.url), ["https://s.test/i0.png", "https://s.test/i1.png", "https://s.test/i2.png"]);
  const feed = log.find((c) => c.u.endsWith("/feed"))!;
  assert.equal(feed.p.message, "leg");
  const ids = [0, 1, 2].map((i) => JSON.parse(feed.p[`attached_media[${i}]`]).media_fbid);
  assert.deepEqual(ids, fotos.map((_, i) => "FOTO" + (i + 2)));
});

test("facebook CAROUSEL com vídeo: falha explicada, SEM nenhuma chamada à Meta", async () => {
  respostas = metaFeliz;
  log = [];
  await assert.rejects(publicarNoFacebook("PAGE", "tok", "x", "CAROUSEL", [IMG(0), VID(1)], O), /nao aceita carrossel com video/);
  assert.equal(log.length, 0);
});

test("facebook: System User sem a Página → erro que diz o que fazer, sem vazar token", async () => {
  respostas = (c) =>
    c.u.includes("?fields=access_token")
      ? { error: { message: "(#10) This endpoint requires the 'pages_read_engagement' permission", code: 10 }, _status: 400 }
      : metaFeliz(c);
  await assert.rejects(
    publicarNoFacebook("1358218360707076", "tok", "x", "IMAGE", [IMG(0)], O),
    (e: Error) => /atribuir a Pagina como ativo do System User/.test(e.message) && !e.message.includes("tok"),
  );
});

test("facebook: erro no upload do vídeo vira exceção", async () => {
  respostas = (c) => (c.u.startsWith("https://rupload.test") ? { error: { message: "fetch falhou" }, _status: 400 } : metaFeliz(c));
  await assert.rejects(publicarNoFacebook("PAGE", "tok", "x", "STORIES", [VID(0)], O), /video_stories upload/);
});
