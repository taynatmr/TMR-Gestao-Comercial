# TMR Gestão Comercial

## Arquivos
- `index.html` — o sistema inteiro (mesmo formato do ISIS: um único arquivo, pronto para o GitHub Pages).
- `supabase/schema.sql` — estrutura completa do banco (todas as etapas), segurança RLS e Storage.

## Abrir só para conhecer (sem Supabase)
Abra o `index.html` direto no navegador. Sem URL configurada, ele entra no **modo de visualização**:
tudo funciona, mas os dados ficam só naquele navegador e **não** são levados para o Supabase depois.
Usuários, troca de senha e e-mail só funcionam conectado. Para apagar os testes: Configurações → Apagar dados de teste.

## Instalação (uma única vez)
1. Crie um projeto **novo** no Supabase (separado do ISIS).
2. Supabase → **SQL Editor** → New query → cole todo o `schema.sql` → **Run**.
   O script pode ser executado de novo depois sem apagar dados.
3. Supabase → **Project Settings → API**: copie a *Project URL* e a chave *anon/publishable*.
4. Escolha uma opção:
   - fixar a conexão: no `index.html`, preencha `window.GC_CONFIG = { url: '...', key: '...' }`; ou
   - deixar em branco: o sistema abre no modo de visualização; clique em "Conectar ao Supabase" (faixa amarela no topo) e informe a URL e a chave.
5. Publique o `index.html` (ex.: um repositório novo no GitHub Pages) e abra.
6. Crie a conta (e-mail + senha) e informe o nome da empresa. Quem cria a empresa vira **Administrador**.

> Se a confirmação de e-mail estiver ativa (Authentication → Sign In / Providers → Email), a pessoa precisa clicar no link recebido antes de entrar.
> Em Authentication → URL Configuration, coloque o endereço do sistema em *Site URL* para os links de confirmação e de "Esqueci a senha" voltarem para ele.

## O que funciona nesta etapa
- **Estoque:** cadastro com foto, pesquisa, filtro por categoria, detalhes, entrada/saída/ajuste de inventário, estoque mínimo e alerta de estoque baixo.
- **Base de Cálculo:** Produto (materiais + horas + lucro, com preço em tempo real), Serviço (valor da hora × horas) e Completo.
- **Serviços:** vitrine com foto, pesquisa, filtro, detalhes e edição.
- **Fornecedores:** cadastro e histórico de compras (entradas de estoque vinculadas).
- **Clientes:** cadastro e tela de detalhes (o histórico aparece quando houver vendas).
- **Configurações:** dados da empresa com logotipo, usuários (administrador/vendedor) e troca de senha.
- **Dashboard:** indicadores de estoque e cadastros.

## Regras garantidas pelo banco
- A quantidade em estoque só muda por movimentação, e o banco não deixa o saldo ficar negativo.
- Não é possível cadastrar dois produtos (ou dois serviços) com o mesmo nome e especificação.
- Vendas guardam o preço e o custo do momento, mesmo que o cadastro mude depois.
- Cancelar uma venda devolve os produtos ao estoque. Um orçamento só vira venda uma vez.
- Movimentações e vendas não podem ser apagadas: o histórico fica preservado.
- Cada empresa só vê os próprios dados. O vendedor não exclui cadastros nem altera a empresa.

## Vendas, Orçamentos, Financeiro e Relatórios
- **Vendas:** cliente → produtos e serviços → quantidades → DESCONTO (R$ ou %) → forma de pagamento (à vista ou parcelado) → confirmar.
  O estoque baixa na confirmação; cancelar a venda devolve os produtos. Ao concluir, o recibo em PDF é gerado e o sistema pergunta se deve enviar ao e-mail do cliente.
- **Orçamentos:** com validade, situação (aberto, enviado, aprovado, recusado), PDF e "Converter em venda" (somente aprovados, uma única vez).
- **Financeiro:** contas a receber por parcela, recebimentos totais ou parciais, estorno (administrador), vencidos, vendas realizadas e histórico por cliente.
- **Relatórios:** vendas, faturamento, lucratividade, produtos vendidos, serviços contratados, movimentação de estoque, financeiro e histórico de clientes — com filtros e exportação em PDF e Excel.
- **Dashboard:** indicadores do mês, gráfico dos últimos 12 meses, mais vendidos, estoque baixo e contas a receber.

Se você já tinha rodado o `schema.sql`, rode a versão nova de novo (não apaga dados).

## Instalar como aplicativo
Todos os arquivos da pasta "enviar-ao-github" (index.html, manifest.webmanifest, sw.js e os 6 arquivos .png) ficam soltos, juntos, na página inicial do repositório.
- **iPhone (Safari):** abrir o endereço → botão Compartilhar → **Adicionar à Tela de Início**.
- **Android (Chrome):** abrir o endereço → menu ⋮ → **Instalar aplicativo** (ou "Adicionar à tela inicial").
- **Computador (Chrome/Edge):** ícone de instalar na barra de endereço.

## Configurações
- **Alterar cores:** temas prontos ou cores personalizadas (vale para o sistema e para os PDFs). "Resetar" volta ao padrão.
- **Menu e funcionalidades:** escolha se a empresa trabalha com mercadorias, serviços ou os dois; oculte itens do menu e mude a ordem (arrastando ou pelas setas). Ocultar não apaga dados.
- **Menu fixo ou suspenso:** o alfinete no topo do menu fixa ou solta o menu; solto, ele abre pelo ☰ (escolha guardada em cada aparelho).

## Histórico de preços
Todo cadastro ou alteração de preço de produto ou serviço fica registrado (data, composição, preço anterior, variação e motivo).
Aparece nos detalhes e na edição do produto/serviço. Ao mudar o preço, o sistema pede um motivo (opcional).

## Envio de e-mail (opcional)
Sem esta configuração, o botão SIM oferece baixar o PDF e abrir seu e-mail já endereçado ao cliente.
Para o envio automático, com o PDF anexado:
1. Crie uma conta em resend.com, verifique o domínio do seu e-mail e gere uma API Key.
2. Supabase → **Edge Functions** → criar a função **`enviar-documento`** e colar o arquivo `supabase/functions/enviar-documento/index.ts`.
3. Supabase → Edge Functions → **Secrets**: `RESEND_API_KEY` (a chave) e `EMAIL_REMETENTE` (ex.: `Minha Loja <vendas@minhaloja.com.br>`).

O destinatário é sempre o e-mail gravado no cadastro do cliente.
