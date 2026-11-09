// Função do Supabase: envia recibo ou orçamento (PDF) para o e-mail cadastrado do cliente.
// Usa o serviço Resend (https://resend.com). Segredos necessários no Supabase:
//   RESEND_API_KEY   → chave da API do Resend
//   EMAIL_REMETENTE  → ex.: "Minha Loja <vendas@minhaloja.com.br>" (domínio verificado no Resend)
// O destinatário é sempre o e-mail do cliente gravado no banco (não o enviado pela tela),
// e a leitura respeita as permissões (RLS) do usuário logado.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const esc = (t: string) => String(t ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const chave = Deno.env.get("RESEND_API_KEY"), remetente = Deno.env.get("EMAIL_REMETENTE");
    if (!chave || !remetente) return resposta({ erro: "Configure os segredos RESEND_API_KEY e EMAIL_REMETENTE no Supabase." }, 500);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { tipo, id, pdf_base64, nome_arquivo } = await req.json();
    if (!["venda", "orcamento"].includes(tipo) || !id || !pdf_base64) return resposta({ erro: "Dados incompletos." }, 400);
    if (pdf_base64.length > 8_000_000) return resposta({ erro: "Arquivo grande demais." }, 400);

    const tabela = tipo === "venda" ? "vendas" : "orcamentos";
    const { data: doc, error } = await sb.from(tabela).select("numero, cliente_id").eq("id", id).single();
    if (error || !doc) return resposta({ erro: "Documento não encontrado ou sem permissão." }, 403);
    const { data: cli } = await sb.from("clientes").select("nome, email").eq("id", doc.cliente_id).single();
    if (!cli?.email) return resposta({ erro: "O cliente não tem e-mail cadastrado." }, 400);
    const { data: emp } = await sb.from("empresas").select("nome_fantasia, razao_social, email, telefone, endereco, logo_url").single();
    const nomeEmp = emp?.nome_fantasia || emp?.razao_social || "";
    const titulo = tipo === "venda" ? `Recibo da venda nº ${doc.numero}` : `Orçamento nº ${doc.numero}`;

    const envio = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: nomeEmp ? `${nomeEmp.replace(/[<>"]/g, "")} <${remetente.match(/<(.+)>/)?.[1] ?? remetente}>` : remetente,
        to: [cli.email],
        reply_to: emp?.email || undefined,
        subject: `${titulo}${nomeEmp ? " — " + nomeEmp : ""}`,
        html: `<div style="font-family:Arial,Helvetica,sans-serif;color:#1d232b;max-width:560px">
          ${emp?.logo_url ? `<img src="${emp.logo_url}" alt="${esc(nomeEmp)}" style="max-height:64px;max-width:200px;margin-bottom:12px">` : ""}
          <h2 style="margin:0 0 16px;font-size:18px">${esc(nomeEmp)}</h2>
          <p>Olá, ${esc(cli.nome)}!</p><p>Segue em anexo o ${esc(titulo.toLowerCase())}.</p>
          <p style="color:#6a7079;font-size:13px;border-top:1px solid #e5e3dd;padding-top:12px;margin-top:24px">
            ${esc(nomeEmp)}${emp?.telefone ? "<br>" + esc(emp.telefone) : ""}${emp?.email ? "<br>" + esc(emp.email) : ""}${emp?.endereco ? "<br>" + esc(emp.endereco) : ""}</p></div>`,
        attachments: [{ filename: nome_arquivo || "documento.pdf", content: pdf_base64 }],
      }),
    });
    if (!envio.ok) return resposta({ erro: "Falha no envio: " + (await envio.text()) }, 502);
    return resposta({ ok: true, para: cli.email });
  } catch (e) {
    return resposta({ erro: String(e?.message || e) }, 500);
  }
});
