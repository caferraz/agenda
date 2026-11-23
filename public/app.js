'use strict';

/* ============================================================
   Agenda de Compromissos - frontend (PWA / SPA)
   ============================================================ */

const API = '/api/compromissos';
const AVISO_PADRAO = 10;          // minutos de antecedência padrão do alarme
const POR_PAGINA_PADRAO = 10;     // registros por página na lista geral
const $ = (id) => document.getElementById(id);

const estado = {
  lista: [],
  mes: inicioDoMes(new Date()),
  diaSel: dataStr(new Date()),
  editId: null,
  recId: null,
  hojeAtual: dataStr(new Date()),
  ocultarVencidos: lerPreferencia('agenda-ocultar-vencidos') === '1',
  porPagina: limitarTamanho(lerPreferencia('agenda-por-pagina') || POR_PAGINA_PADRAO),
  pagina: 1,
};

function limitarTamanho(v) {
  const n = Math.floor(Number(v));
  return Number.isFinite(n) && n >= 1 ? Math.min(n, 500) : POR_PAGINA_PADRAO;
}

function lerPreferencia(chave) {
  try { return localStorage.getItem(chave); } catch { return null; }
}

/* ---------------- utilidades de data ---------------- */
function pad(n) { return String(n).padStart(2, '0'); }
function dataStr(d) { return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; }
function horaStr(d) { return `${pad(d.getHours())}:${pad(d.getMinutes())}`; }
function inicioDoMes(d) { return new Date(d.getFullYear(), d.getMonth(), 1); }
function minutos(h) { const [a, b] = h.split(':').map(Number); return a * 60 + b; }
function dataHora(data, hora) {
  const [y, m, d] = data.split('-').map(Number);
  const [hh, mm] = hora.split(':').map(Number);
  return new Date(y, m - 1, d, hh, mm, 0, 0);
}
function fmtDiaLongo(s) {
  const [y, m, d] = s.split('-').map(Number);
  const txt = new Date(y, m - 1, d).toLocaleDateString('pt-BR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  return txt.charAt(0).toUpperCase() + txt.slice(1);
}
function fmtDiaCurto(s) { const [, m, d] = s.split('-'); return `${d}/${m}`; }
function fmtDiaSemana(s) {
  const [y, m, d] = s.split('-').map(Number);
  const sem = new Date(y, m - 1, d).toLocaleDateString('pt-BR', { weekday: 'short' }).replace('.', '');
  return `${sem} ${fmtDiaCurto(s)}`;
}
function fmtAviso(min) {
  if (min === 0) return 'no horário';
  if (min % 1440 === 0) return `${min / 1440} dia(s) antes`;
  if (min % 60 === 0) return `${min / 60} h antes`;
  return `${min} min antes`;
}
function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function vencido(c) { return dataHora(c.data, c.inicio) <= new Date(); }
function externo(c) { return !!c.calendarioId; }
function editavel(c) { return !externo(c) && !c.alarmado && !vencido(c); }
function motivoBloqueio(c) {
  if (externo(c)) return `Evento importado de "${c.origem}": altere ou exclua na agenda de origem.`;
  if (vencido(c)) return 'Compromisso vencido: não pode mais ser alterado ou excluído.';
  if (c.alarmado) return 'Compromisso já alarmado: não pode mais ser alterado ou excluído.';
  return '';
}
function sobrepoe(a, b) { return minutos(a.inicio) < minutos(b.fim) && minutos(a.fim) > minutos(b.inicio); }

/* Momento do próximo alarme do compromisso (ou null se não houver mais) */
function proximoAlarme(c) {
  const ini = dataHora(c.data, c.inicio);
  if (!c.alarmado) return new Date(ini.getTime() - c.avisoMinutos * 60000);
  if (c.adiadoPara != null) return new Date(ini.getTime() - c.adiadoPara * 60000);
  return null;
}

/* O compromisso que tocará o próximo alarme */
function compromissoDoProximoAlarme() {
  const agora = new Date();
  let melhor = null, tMelhor = null;
  for (const c of estado.lista) {
    const t = proximoAlarme(c);
    if (!t || dataHora(c.data, c.fim) <= agora) continue;
    if (!melhor || t < tMelhor) { melhor = c; tMelhor = t; }
  }
  return melhor;
}

/* ---------------- tema claro / escuro ---------------- */
function temaEfetivo() {
  const t = document.documentElement.dataset.theme;
  if (t === 'light' || t === 'dark') return t;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function atualizarBotaoTema() {
  const escuro = temaEfetivo() === 'dark';
  $('btnTema').textContent = escuro ? '☀️ Tema claro' : '🌙 Tema escuro';
  document.querySelector('meta[name="theme-color"]').content = escuro ? '#111a2e' : '#2563eb';
}
function alternarTema() {
  const novo = temaEfetivo() === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = novo;
  try { localStorage.setItem('agenda-tema', novo); } catch { /* armazenamento indisponível */ }
  atualizarBotaoTema();
}

/* ---------------- API ---------------- */
async function api(metodo, url, corpo) {
  let r;
  try {
    r = await fetch(url, {
      method: metodo,
      headers: corpo ? { 'Content-Type': 'application/json' } : {},
      body: corpo ? JSON.stringify(corpo) : undefined,
      cache: 'no-store',
    });
  } catch (e) {
    $('avisoOffline').hidden = false;
    throw new Error('Sem comunicação com o servidor.');
  }
  $('avisoOffline').hidden = true;
  let dados = null;
  try { dados = await r.json(); } catch { /* sem corpo */ }
  if (!r.ok) {
    const err = new Error((dados && dados.erro) || `Erro ${r.status}`);
    err.status = r.status; err.dados = dados;
    throw err;
  }
  return dados;
}

async function carregar() {
  try {
    const dados = await api('GET', API);
    estado.lista = Array.isArray(dados) ? dados : (dados ? [dados] : []);
    // se estava editando algo que sumiu, venceu ou foi alarmado, cancela a edição
    if (estado.editId) {
      const c = estado.lista.find((x) => x.id === estado.editId);
      if (!c || !editavel(c)) cancelarEdicao();
    }
    render();
  } catch (e) {
    console.warn(e);
  }
}

/* ---------------- renderização ---------------- */
function render() {
  renderCalendario();
  renderDia();
  renderGeral();
  checarConflitoAoDigitar();
}

function renderCalendario() {
  const m = estado.mes;
  const tm = m.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });
  $('mesTitulo').textContent = tm.charAt(0).toUpperCase() + tm.slice(1);
  const hoje = dataStr(new Date());
  const contagem = {};
  for (const c of estado.lista) contagem[c.data] = (contagem[c.data] || 0) + 1;

  const frag = document.createDocumentFragment();
  for (let i = 0; i < m.getDay(); i++) {
    const b = document.createElement('button'); b.className = 'dia vazio'; b.disabled = true; b.tabIndex = -1;
    frag.appendChild(b);
  }
  const diasNoMes = new Date(m.getFullYear(), m.getMonth() + 1, 0).getDate();
  for (let d = 1; d <= diasNoMes; d++) {
    const s = `${m.getFullYear()}-${pad(m.getMonth() + 1)}-${pad(d)}`;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'dia';
    b.textContent = d;
    if (s === hoje) b.classList.add('hoje');
    if (s === estado.diaSel) b.classList.add('sel');
    if (s < hoje) { b.disabled = true; b.title = 'Dia anterior (compromissos são excluídos automaticamente)'; }
    if (contagem[s]) {
      const q = document.createElement('span'); q.className = 'qtd'; q.textContent = contagem[s];
      b.appendChild(q);
      b.title = `${contagem[s]} compromisso(s)`;
    }
    b.addEventListener('click', () => selecionarDia(s));
    frag.appendChild(b);
  }
  $('calDias').replaceChildren(frag);
  $('mesAnt').disabled = m <= inicioDoMes(new Date());
}

function textoStatus(c) {
  if (vencido(c)) return 'Vencido / em andamento';
  if (c.alarmado && c.adiadoPara != null) return `⏸ Adiado: novo alarme às ${horaStr(proximoAlarme(c))} (${c.adiadoPara} min antes)`;
  if (c.alarmado) return '🔔 Alarmado';
  return `Alarme às ${horaStr(proximoAlarme(c))} (${fmtAviso(c.avisoMinutos)})`;
}

/* Exibir / esconder compromissos vencidos (vale para as duas listas) */
function visivel(c) { return !estado.ocultarVencidos || !vencido(c); }
function msgOcultos(n) {
  if (!n) return '';
  return `<li class="vazio-msg ocultos">${n === 1 ? '1 compromisso vencido oculto.' : `${n} compromissos vencidos ocultos.`}</li>`;
}
function atualizarBotaoVencidos() {
  const n = estado.lista.filter(vencido).length;
  const b = $('btnVencidos');
  b.textContent = estado.ocultarVencidos ? `👁 Mostrar vencidos (${n})` : `🙈 Esconder vencidos (${n})`;
  b.setAttribute('aria-pressed', String(estado.ocultarVencidos));
  b.title = estado.ocultarVencidos
    ? 'Voltar a exibir os compromissos que já começaram'
    : 'Esconder das listas os compromissos que já começaram';
}
function alternarVencidos() {
  estado.ocultarVencidos = !estado.ocultarVencidos;
  try { localStorage.setItem('agenda-ocultar-vencidos', estado.ocultarVencidos ? '1' : '0'); } catch { /* indisponível */ }
  render();
}

function renderDia() {
  $('diaTitulo').textContent = fmtDiaLongo(estado.diaSel);
  const doDia = estado.lista.filter((c) => c.data === estado.diaSel);
  const itens = doDia.filter(visivel).sort((a, b) => a.inicio.localeCompare(b.inicio));
  const ocultos = msgOcultos(doDia.length - itens.length);
  const ul = $('listaDia');
  if (!itens.length) {
    ul.innerHTML = (doDia.length ? '<li class="vazio-msg">Nenhum compromisso a vencer neste dia.</li>' : '<li class="vazio-msg">Nenhum compromisso neste dia.</li>') + ocultos;
    return;
  }
  ul.innerHTML = itens.map((c) => {
    const venc = vencido(c);
    const pode = editavel(c);
    const serie = (c.serieId ? ' · 🔁 recorrente' : '') + seloOrigem(c);
    const bloqueio = pode ? '' : `disabled title="${esc(motivoBloqueio(c))}"`;
    return `
      <li class="${c.alarmado || venc ? 'alarmado' : ''} ${c.id === estado.editId ? 'editando' : ''}">
        <div>
          <div><span class="hora">${c.inicio} – ${c.fim}</span> · <span class="tit">${esc(c.titulo)}</span></div>
          <div class="meta">${textoStatus(c)}${serie}${marcaSobreposto(c)}</div>
        </div>
        <div class="acoes">
          <button class="btn sec peq" data-acao="editar" data-id="${c.id}" ${bloqueio}>Editar</button>
          <button class="btn perigo peq" data-acao="excluir" data-id="${c.id}" ${bloqueio}>Excluir</button>
          <button class="btn sec peq" data-acao="recorrencia" data-id="${c.id}" ${venc ? 'disabled title="Compromisso já vencido"' : (externo(c) ? `disabled title="${esc(motivoBloqueio(c))}"` : '')}>🔁 Recorrência</button>
        </div>
      </li>`;
  }).join('') + ocultos;
}

function renderGeral() {
  atualizarBotaoVencidos();
  const ul = $('listaGeral');
  const itens = estado.lista.filter(visivel).sort((a, b) => (a.data + a.inicio).localeCompare(b.data + b.inicio));
  const ocultos = msgOcultos(estado.lista.length - itens.length);
  const pagina = paginar(itens);
  if (!itens.length) {
    ul.innerHTML = (estado.lista.length ? '<li class="vazio-msg">Nenhum compromisso a vencer.</li>' : '<li class="vazio-msg">Nenhum compromisso cadastrado.</li>') + ocultos;
    return;
  }
  const prox = compromissoDoProximoAlarme();
  const cab = '<li class="cab"><span>Data</span><span>Horário</span><span>Título</span><span>Situação</span></li>';
  ul.innerHTML = cab + pagina.map((c) => {
    const pode = editavel(c);
    const classes = [
      pode ? 'clicavel' : 'bloqueado',
      c.id === estado.editId ? 'editando' : '',
      prox && c.id === prox.id ? 'proximo' : '',
    ].join(' ');
    const selo = prox && c.id === prox.id
      ? `<span class="selo ${c.adiadoPara != null ? 'adiado' : ''}">⏰ Próximo alarme às ${horaStr(proximoAlarme(c))}</span> `
      : '';
    const attrs = pode
      ? `tabindex="0" role="button" aria-label="Alterar ou excluir ${esc(c.titulo)}"`
      : `title="${esc(motivoBloqueio(c))}"`;
    return `
      <li class="${classes}" data-id="${c.id}" ${attrs}>
        <span class="col-h">${fmtDiaSemana(c.data)}</span>
        <span class="col-h">${c.inicio} – ${c.fim}</span>
        <span class="col-t">${selo}${esc(c.titulo)}${c.serieId ? ' 🔁' : ''}${seloOrigem(c)}${marcaSobreposto(c)}</span>
        <span class="col-s">${textoStatus(c)}</span>
      </li>`;
  }).join('') + ocultos;
}

/* ---------------- paginação da lista geral ---------------- */
function totalPaginas(n) { return Math.max(1, Math.ceil(n / estado.porPagina)); }

/* Recorta a página atual (ajustando-a se a lista encolheu) e atualiza os controles */
function paginar(itens) {
  const total = totalPaginas(itens.length);
  estado.pagina = Math.min(Math.max(1, estado.pagina), total);
  const ini = (estado.pagina - 1) * estado.porPagina;
  const fatia = itens.slice(ini, ini + estado.porPagina);

  $('paginacao').hidden = itens.length === 0;
  if (document.activeElement !== $('pagTamanho')) $('pagTamanho').value = estado.porPagina;
  if (document.activeElement !== $('pagAtual')) $('pagAtual').value = estado.pagina;
  $('pagAtual').max = total;
  $('pagTotal').textContent = total;
  $('pagInfo').textContent = itens.length
    ? `Mostrando ${ini + 1}–${ini + fatia.length} de ${itens.length}`
    : '';
  $('pagPrimeira').disabled = $('pagAnterior').disabled = estado.pagina <= 1;
  $('pagProxima').disabled = $('pagUltima').disabled = estado.pagina >= total;
  return fatia;
}

function irParaPagina(p) {
  estado.pagina = Math.floor(Number(p)) || 1;
  renderGeral();
}

function mudarTamanhoPagina(v) {
  const primeiro = (estado.pagina - 1) * estado.porPagina;      // mantém o 1º registro visível
  estado.porPagina = limitarTamanho(v);
  try { localStorage.setItem('agenda-por-pagina', String(estado.porPagina)); } catch { /* indisponível */ }
  estado.pagina = Math.floor(primeiro / estado.porPagina) + 1;
  $('pagTamanho').value = estado.porPagina;
  renderGeral();
}

/* ---------------- seleção de dia / formulário ---------------- */
function selecionarDia(s) {
  estado.diaSel = s;
  const [y, m] = s.split('-').map(Number);
  estado.mes = new Date(y, m - 1, 1);
  render();
}

function lerFormulario() {
  return {
    titulo: $('titulo').value.trim(),
    data: estado.diaSel,
    inicio: $('inicio').value,
    fim: $('fim').value,
    avisoMinutos: Number($('aviso').value),
  };
}

function conflitosLocais(d) {
  if (!d.inicio || !d.fim || minutos(d.fim) <= minutos(d.inicio)) return [];
  return estado.lista.filter((c) => c.data === d.data && c.id !== estado.editId && sobrepoe(d, c));
}

function checarConflitoAoDigitar() {
  const d = lerFormulario();
  const box = $('conflito');
  const msgs = [];
  if (d.inicio && d.fim && minutos(d.fim) <= minutos(d.inicio)) {
    msgs.push('O horário final deve ser maior que o horário inicial.');
  }
  const conf = conflitosLocais(d);
  if (conf.length) {
    msgs.push('⚠️ Conflito de agendamento com: ' + conf.map((c) => `<strong>${esc(c.titulo)}</strong> (${c.inicio}–${c.fim})`).join(', ') +
      '. Ao salvar, você poderá confirmar se deseja incluir mesmo assim.');
  }
  box.innerHTML = msgs.join('<br>');
  box.hidden = msgs.length === 0;
}

async function salvar(ev) {
  ev.preventDefault();
  const d = lerFormulario();
  if (!d.titulo) return toast('Informe o título.', 'erro');
  if (!d.inicio || !d.fim) return toast('Informe os horários inicial e final.', 'erro');
  if (minutos(d.fim) <= minutos(d.inicio)) return toast('O horário final deve ser maior que o inicial.', 'erro');
  if (dataHora(d.data, d.fim) <= new Date()) return toast('Esse horário já passou.', 'erro');

  // conflito: informa e pergunta se deseja incluir/alterar mesmo assim
  let forcar = false;
  const conf = conflitosLocais(d);
  if (conf.length) {
    if (!(await perguntarConflito(d, conf))) return;
    forcar = true;
  }

  try {
    await enviarCompromisso(d, forcar);
  } catch (e) {
    // o servidor pode encontrar um conflito que a tela ainda não conhecia (ex.: incluído em outra janela)
    if (e.status === 409 && e.dados && e.dados.codigo === 'conflito' && !forcar) {
      if (await perguntarConflito(d, e.dados.conflitos || [])) {
        try { await enviarCompromisso(d, true); } catch (e2) { toast(e2.message, 'erro', 6000); }
      }
      return carregar();
    }
    toast(e.message, 'erro', 6000);
    if (e.status === 404 || e.status === 409) carregar();
  }
}

async function enviarCompromisso(d, forcar) {
  const corpo = forcar ? { ...d, forcar: true } : d;
  const aviso = forcar ? ' (com conflito de horário)' : '';
  if (estado.editId) {
    await api('PUT', `${API}/${estado.editId}`, corpo);
    toast(`Compromisso alterado${aviso}.`, 'ok');
    cancelarEdicao();
  } else {
    await api('POST', API, corpo);
    toast(`Compromisso agendado${aviso}.`, 'ok');
    limparFormulario();
  }
  await carregar();
}

/* Diálogo "Conflito de agendamento — deseja incluir mesmo assim?" -> Promise<boolean> */
function perguntarConflito(d, conflitos) {
  const editando = !!estado.editId;
  $('conflitoIntro').innerHTML =
    `<strong>${esc(d.titulo)}</strong> (${fmtDiaCurto(d.data)}, ${d.inicio}–${d.fim}) coincide com:`;
  $('conflitoItens').innerHTML = conflitos.map((c) =>
    `<li><strong>${c.inicio}–${c.fim}</strong> · ${esc(c.titulo)}</li>`).join('');
  $('conflitoAcao').textContent = editando ? 'salvar a alteração' : 'incluir';
  $('btnConflitoSim').textContent = editando ? 'Sim, salvar mesmo assim' : 'Sim, incluir mesmo assim';
  const dlg = $('dlgConflito');
  return new Promise((resolve) => {
    const fim = (resp) => {
      $('btnConflitoSim').removeEventListener('click', sim);
      $('btnConflitoNao').removeEventListener('click', nao);
      dlg.removeEventListener('cancel', nao);
      if (dlg.open) dlg.close();
      resolve(resp);
    };
    const sim = () => fim(true);
    const nao = (ev) => { if (ev) ev.preventDefault(); fim(false); };
    $('btnConflitoSim').addEventListener('click', sim);
    $('btnConflitoNao').addEventListener('click', nao);
    dlg.addEventListener('cancel', nao);
    dlg.showModal();
    $('btnConflitoNao').focus();   // padrão seguro: Enter não inclui por engano
  });
}

/* Compromissos já gravados que se sobrepõem a este */
function sobrepostosA(c) {
  return estado.lista.filter((o) => o.id !== c.id && o.data === c.data && sobrepoe(c, o));
}
function marcaSobreposto(c) {
  const s = sobrepostosA(c);
  if (!s.length) return '';
  const dica = 'Horário coincide com: ' + s.map((o) => `${o.titulo} (${o.inicio}–${o.fim})`).join(', ');
  return ` <span class="sobreposto" title="${esc(dica)}">⚠️ conflito de horário</span>`;
}

function limparFormulario() {
  $('titulo').value = '';
  $('inicio').value = '';
  $('fim').value = '';
  $('aviso').value = String(AVISO_PADRAO);
  checarConflitoAoDigitar();
}

function iniciarEdicao(c) {
  if (!editavel(c)) { toast(motivoBloqueio(c), 'erro'); return; }
  if (c.data !== estado.diaSel) selecionarDia(c.data);
  estado.editId = c.id;
  $('titulo').value = c.titulo;
  $('inicio').value = c.inicio;
  $('fim').value = c.fim;
  $('aviso').value = String(c.avisoMinutos);
  if ($('aviso').value !== String(c.avisoMinutos)) {   // valor fora da lista
    $('aviso').add(new Option(fmtAviso(c.avisoMinutos), c.avisoMinutos));
    $('aviso').value = String(c.avisoMinutos);
  }
  $('btnSalvar').textContent = 'Salvar alterações';
  $('btnCancelar').hidden = false;
  $('btnExcluirForm').hidden = false;
  renderDia();
  renderGeral();
  checarConflitoAoDigitar();
  $('form').scrollIntoView({ behavior: 'smooth', block: 'center' });
  $('titulo').focus({ preventScroll: true });
}

function cancelarEdicao() {
  estado.editId = null;
  $('btnSalvar').textContent = 'Agendar';
  $('btnCancelar').hidden = true;
  $('btnExcluirForm').hidden = true;
  limparFormulario();
  renderDia();
  renderGeral();
}

async function excluir(c) {
  if (!editavel(c)) { toast(motivoBloqueio(c), 'erro'); return; }
  if (!confirm(`Excluir o compromisso "${c.titulo}" (${fmtDiaCurto(c.data)} ${c.inicio}–${c.fim})?`)) return;
  try {
    await api('DELETE', `${API}/${c.id}`);
    if (estado.editId === c.id) cancelarEdicao();
    toast('Compromisso excluído.', 'ok');
  } catch (e) {
    toast(e.message, 'erro', 6000);
  }
  carregar();
}

/* ---------------- recorrência ---------------- */
function abrirRecorrencia(c) {
  estado.recId = c.id;
  $('recInfo').innerHTML = `<strong>${esc(c.titulo)}</strong><br>${fmtDiaLongo(c.data)}, ${c.inicio}–${c.fim}`;
  atualizarPrevia();
  $('dlgRec').showModal();
}

function datasRecorrencia(c, tipo, qtd) {
  const [y, m, d] = c.data.split('-').map(Number);
  const out = [];
  for (let i = 1; i <= qtd; i++) {
    let dt;
    if (tipo === 'diaria') dt = new Date(y, m - 1, d + i);
    else if (tipo === 'semanal') dt = new Date(y, m - 1, d + 7 * i);
    else {
      // mensal: se o dia não existir no mês (ex.: 31), usa o último dia do mês (mesma regra do servidor)
      const ultimo = new Date(y, m - 1 + i + 1, 0).getDate();
      dt = new Date(y, m - 1 + i, Math.min(d, ultimo));
    }
    out.push(dataStr(dt));
  }
  return out;
}

function atualizarPrevia() {
  const c = estado.lista.find((x) => x.id === estado.recId);
  if (!c) return;
  const qtd = Math.max(1, Math.min(60, Number($('recQtd').value) || 1));
  const datas = datasRecorrencia(c, $('recTipo').value, qtd);
  const conflitos = datas.filter((ds) => estado.lista.some((o) => o.data === ds && sobrepoe(c, o)));
  let txt = `Datas: ${datas.map(fmtDiaCurto).join(', ')}.`;
  if (conflitos.length) txt += ` ⚠️ ${conflitos.length} data(s) com conflito serão ignoradas: ${conflitos.map(fmtDiaCurto).join(', ')}.`;
  $('recPrevia').textContent = txt;
}

async function confirmarRecorrencia() {
  const qtd = Number($('recQtd').value);
  if (!(qtd >= 1 && qtd <= 60)) return toast('Informe de 1 a 60 repetições.', 'erro');
  try {
    const r = await api('POST', `${API}/${estado.recId}/recorrencia`, { tipo: $('recTipo').value, quantidade: qtd });
    $('dlgRec').close();
    const criados = (r.criados || []).length;
    const ign = r.ignorados || [];
    toast(`${criados} ocorrência(s) criada(s).`, 'ok');
    if (ign.length) {
      toast(`${ign.length} ignorada(s) por conflito: ` + ign.map((i) => `${fmtDiaCurto(i.data)} – ${i.motivo}`).join('; '), 'erro', 9000);
    }
  } catch (e) {
    toast(e.message, 'erro', 6000);
  }
  carregar();
}

/* ---------------- toasts ---------------- */
function toast(msg, tipo = '', ms = 3500) {
  const el = document.createElement('div');
  el.className = `toast ${tipo}`;
  el.textContent = msg;
  $('toasts').appendChild(el);
  setTimeout(() => el.remove(), ms);
}

/* ---------------- relógio / virada de dia ---------------- */
let ultimoMinuto = -1;
function tick() {
  const agora = new Date();
  $('relogio').textContent = agora.toLocaleString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const hoje = dataStr(agora);
  if (hoje !== estado.hojeAtual) {         // virou o dia: limpa os compromissos de ontem
    estado.hojeAtual = hoje;
    if (estado.diaSel < hoje) estado.diaSel = hoje;
    estado.mes = inicioDoMes(agora);
    carregar();
  } else if (agora.getMinutes() !== ultimoMinuto) {
    ultimoMinuto = agora.getMinutes();     // a cada minuto, atualiza "vencido" e o destaque do próximo alarme
    renderDia();
    renderGeral();
  }
}

/* ---------------- eventos ---------------- */
function ligarEventos() {
  $('form').addEventListener('submit', salvar);
  $('btnCancelar').addEventListener('click', cancelarEdicao);
  $('btnExcluirForm').addEventListener('click', () => {
    const c = estado.lista.find((x) => x.id === estado.editId);
    if (c) excluir(c);
  });
  ['inicio', 'fim'].forEach((id) => $(id).addEventListener('input', checarConflitoAoDigitar));

  $('mesAnt').addEventListener('click', () => { estado.mes = new Date(estado.mes.getFullYear(), estado.mes.getMonth() - 1, 1); renderCalendario(); });
  $('mesProx').addEventListener('click', () => { estado.mes = new Date(estado.mes.getFullYear(), estado.mes.getMonth() + 1, 1); renderCalendario(); });
  $('btnHoje').addEventListener('click', () => selecionarDia(dataStr(new Date())));

  $('listaDia').addEventListener('click', (ev) => {
    const b = ev.target.closest('button[data-acao]');
    if (!b) return;
    const c = estado.lista.find((x) => x.id === b.dataset.id);
    if (!c) return;
    if (b.dataset.acao === 'editar') iniciarEdicao(c);
    else if (b.dataset.acao === 'excluir') excluir(c);
    else if (b.dataset.acao === 'recorrencia') abrirRecorrencia(c);
  });

  const abrirDaLista = (ev) => {
    const li = ev.target.closest('li[data-id]');
    if (!li) return;
    const c = estado.lista.find((x) => x.id === li.dataset.id);
    if (!c) return;
    if (editavel(c)) iniciarEdicao(c);
    else { selecionarDia(c.data); toast(motivoBloqueio(c), 'erro'); }
  };
  $('btnVencidos').addEventListener('click', alternarVencidos);
  $('pagPrimeira').addEventListener('click', () => irParaPagina(1));
  $('pagAnterior').addEventListener('click', () => irParaPagina(estado.pagina - 1));
  $('pagProxima').addEventListener('click', () => irParaPagina(estado.pagina + 1));
  $('pagUltima').addEventListener('click', () => irParaPagina(Infinity));
  $('pagAtual').addEventListener('change', (ev) => irParaPagina(ev.target.value));
  $('pagTamanho').addEventListener('change', (ev) => mudarTamanhoPagina(ev.target.value));
  for (const id of ['pagAtual', 'pagTamanho']) {
    $(id).addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); ev.target.blur(); } });
  }
  $('listaGeral').addEventListener('click', abrirDaLista);
  $('listaGeral').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); abrirDaLista(ev); }
  });

  $('recTipo').addEventListener('change', atualizarPrevia);
  $('recQtd').addEventListener('input', atualizarPrevia);
  $('btnRecOk').addEventListener('click', confirmarRecorrencia);

  $('btnTema').addEventListener('click', alternarTema);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', atualizarBotaoTema);

  $('btnTestarAlarme').addEventListener('click', testarAlarme);

  $('btnCalendarios').addEventListener('click', abrirCalendarios);
  $('btnFecharCal').addEventListener('click', () => { $('dlgCalendarios').close(); pararAcompanharSinc(); });
  $('dlgCalendarios').addEventListener('close', pararAcompanharSinc);
  $('btnAdicionarCal').addEventListener('click', adicionarCalendario);
  $('btnSincronizar').addEventListener('click', sincronizarAgora);
  $('listaCal').addEventListener('click', (ev) => {
    const b = ev.target.closest('button[data-cal]');
    if (b) removerCalendario(b.dataset.cal, b.dataset.nome);
  });
  $('listaCal').addEventListener('change', (ev) => {
    const ch = ev.target.closest('input[data-cal-ativo]');
    if (ch) alternarCalendario(ch.dataset.calAtivo, ch.checked);
  });

  $('btnCelular').addEventListener('click', abrirCelular);
  $('btnSalvarCelular').addEventListener('click', () => salvarCelular());
  $('btnTesteCelular').addEventListener('click', testeCelular);
  $('btnNovoTopico').addEventListener('click', novoTopico);
  $('btnCopiarTopico').addEventListener('click', copiarTopico);
  $('btnFecharCelular').addEventListener('click', () => $('dlgCelular').close());
  ['celAdiar', 'celIp'].forEach((id) => $(id).addEventListener('change', () => { if (celCfg) $('celRedeStatus').textContent = statusRede(celCfg); }));
  document.addEventListener('visibilitychange', () => { if (!document.hidden) carregar(); });
}

/* ---------------- alarme ----------------
   O alarme é disparado pelo SERVIDOR, que abre uma janela própria do Windows sempre na frente
   das outras (com som), mesmo com o navegador minimizado ou em outra aba. A página só reflete
   a situação (alarmado / adiado) ao sincronizar. */
async function testarAlarme() {
  try {
    await api('POST', '/api/testar-alarme');
    toast('Janela de alarme de teste aberta pelo Windows.', 'ok');
  } catch (e) {
    toast(e.message, 'erro', 6000);
  }
}

/* ---------------- calendários externos (Outlook / Google) ---------------- */
function seloOrigem(c) {
  return externo(c) ? ` <span class="selo origem" title="Importado de ${esc(c.origem)} (somente leitura)">📅 ${esc(c.origem)}</span>` : '';
}

let timerSinc = null;
function pararAcompanharSinc() { if (timerSinc) { clearInterval(timerSinc); timerSinc = null; } }

function textoStatusCal(c) {
  if (!c.ativo) return '⏸ Desativado';
  const s = c.status;
  if (!s) return '⏳ Aguardando a primeira sincronização…';
  const hora = s.sincronizadoEm ? new Date(s.sincronizadoEm).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : '';
  if (!s.ok) return `⚠️ Falhou às ${hora}: ${s.erro || 'erro desconhecido'}`;
  const dia = s.diaInteiro ? ` · ${s.diaInteiro} de dia inteiro ignorado(s)` : '';
  return `✅ ${s.ocorrencias} compromisso(s) nos próximos 60 dias · sincronizado às ${hora}${dia}`;
}

async function renderCalendarios() {
  let r;
  try { r = await api('GET', '/api/calendarios'); } catch (e) { toast(e.message, 'erro', 6000); return null; }
  const ul = $('listaCal');
  ul.innerHTML = r.calendarios.length
    ? r.calendarios.map((c) => `
      <li>
        <label class="check"><input type="checkbox" data-cal-ativo="${c.id}" ${c.ativo ? 'checked' : ''}> <strong>${esc(c.nome)}</strong></label>
        <div class="meta">${esc(c.url)} · aviso ${fmtAviso(c.avisoMinutos)}</div>
        <div class="meta">${esc(textoStatusCal(c))}</div>
        <button class="btn perigo peq" type="button" data-cal="${c.id}" data-nome="${esc(c.nome)}">Remover</button>
      </li>`).join('')
    : '<li class="vazio-msg">Nenhum calendário conectado ainda.</li>';
  $('calSinc').textContent = r.sincronizando ? '🔄 Sincronizando…' : `Sincroniza automaticamente a cada ${r.intervaloMin} minutos.`;
  return r;
}

function acompanharSinc() {
  pararAcompanharSinc();
  let voltas = 0;
  timerSinc = setInterval(async () => {
    const r = await renderCalendarios();
    if ((r && !r.sincronizando && voltas > 0) || ++voltas > 40) { pararAcompanharSinc(); carregar(); }
  }, 1500);
}

async function abrirCalendarios() {
  await renderCalendarios();
  $('dlgCalendarios').showModal();
}

async function adicionarCalendario() {
  const d = { nome: $('calNome').value.trim(), url: $('calUrl').value.trim(), avisoMinutos: Number($('calAviso').value) };
  if (!d.nome) return toast('Dê um nome ao calendário (ex.: Outlook Intecom).', 'erro');
  if (!d.url) return toast('Cole o link ICS/iCal do calendário.', 'erro');
  try {
    await api('POST', '/api/calendarios', d);
    $('calNome').value = ''; $('calUrl').value = '';
    toast('Calendário adicionado. Sincronizando…', 'ok');
    acompanharSinc();
  } catch (e) { toast(e.message, 'erro', 7000); }
}

async function removerCalendario(id, nome) {
  if (!confirm(`Remover o calendário "${nome}"? Os eventos importados dele saem da agenda (no ${nome} nada muda).`)) return;
  try { await api('DELETE', `/api/calendarios/${id}`); toast('Calendário removido.', 'ok'); } catch (e) { toast(e.message, 'erro', 6000); }
  await renderCalendarios();
  carregar();
}

async function alternarCalendario(id, ativo) {
  try { await api('PUT', `/api/calendarios/${id}`, { ativo }); } catch (e) { toast(e.message, 'erro', 6000); }
  if (ativo) acompanharSinc(); else { await renderCalendarios(); carregar(); }
}

async function sincronizarAgora() {
  try { await api('POST', '/api/calendarios/sincronizar'); acompanharSinc(); } catch (e) { toast(e.message, 'erro', 6000); }
}

/* ---------------- alertas no celular / smartwatch (ntfy) ---------------- */
let celCfg = null;

function statusRede(cfg) {
  if (!$('celAdiar').checked) return '';
  if (!$('celIp').value) return '⚠️ Escolha o endereço deste computador na rede (o mesmo Wi-Fi do celular).';
  if (cfg.redeLiberada) return '✅ Servidor aceitando o comando de adiar pela rede.';
  return '⚠️ Ainda não liberado: execute liberar-rede.bat como administrador e reinicie o servidor (iniciar.bat).';
}

async function abrirCelular() {
  try {
    celCfg = await api('GET', '/api/celular');
  } catch (e) { return toast(e.message, 'erro', 6000); }
  $('celTopico').textContent = celCfg.topico;
  $('celAtivo').checked = !!celCfg.ativo;
  $('celTitulo').checked = !!celCfg.mostrarTitulo;
  $('celPrioridade').value = String(celCfg.prioridade);
  $('celAdiar').checked = !!celCfg.adiarPeloCelular;
  const ips = celCfg.enderecos || [];
  $('celIp').innerHTML = '<option value="">— selecione —</option>' +
    ips.map((x) => `<option value="${esc(x.ip)}">${esc(x.ip)} (${esc(x.rede)})</option>`).join('');
  if (celCfg.enderecoRede && !ips.some((x) => x.ip === celCfg.enderecoRede)) {
    $('celIp').add(new Option(celCfg.enderecoRede, celCfg.enderecoRede));
  }
  $('celIp').value = celCfg.enderecoRede || '';
  $('celRedeStatus').textContent = statusRede(celCfg);
  if (celCfg.adiarPeloCelular) $('dlgCelular').querySelector('details').open = true;
  $('dlgCelular').showModal();
}

function lerCelular() {
  return {
    ativo: $('celAtivo').checked,
    mostrarTitulo: $('celTitulo').checked,
    prioridade: Number($('celPrioridade').value),
    adiarPeloCelular: $('celAdiar').checked,
    enderecoRede: $('celIp').value,
  };
}

async function salvarCelular(silencioso = false) {
  const d = lerCelular();
  try {
    await api('PUT', '/api/celular', d);
    const mudouRede = celCfg && (d.adiarPeloCelular !== !!celCfg.adiarPeloCelular);
    celCfg = { ...celCfg, ...d };
    $('celRedeStatus').textContent = statusRede(celCfg);
    if (!silencioso) {
      toast('Configuração do celular salva.', 'ok');
      if (mudouRede) toast('Para ativar/desativar os botões de adiar, reinicie o servidor (iniciar.bat).', '', 7000);
    }
    return true;
  } catch (e) { toast(e.message, 'erro', 6000); return false; }
}

async function testeCelular() {
  if (!(await salvarCelular(true))) return;
  try {
    await api('POST', '/api/celular/teste');
    toast('Notificação de teste enviada. Confira o celular e o relógio.', 'ok', 5000);
  } catch (e) { toast(e.message, 'erro', 8000); }
}

async function novoTopico() {
  if (!confirm('Gerar um novo tópico? O celular deixará de receber até você se inscrever no novo tópico no app ntfy.')) return;
  try {
    const r = await api('PUT', '/api/celular', { novoTopico: true });
    celCfg.topico = r.topico;
    $('celTopico').textContent = r.topico;
    toast('Novo tópico gerado. Inscreva-se nele no app ntfy.', 'ok', 5000);
  } catch (e) { toast(e.message, 'erro', 6000); }
}

async function copiarTopico() {
  const t = $('celTopico').textContent;
  try { await navigator.clipboard.writeText(t); toast('Tópico copiado.', 'ok'); }
  catch {
    const r = document.createRange(); r.selectNodeContents($('celTopico'));
    const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    toast('Selecionei o tópico: tecle Ctrl+C para copiar.');
  }
}

/* ---------------- inicialização ---------------- */
function iniciar() {
  ligarEventos();
  atualizarBotaoTema();
  $('aviso').value = String(AVISO_PADRAO);
  tick();
  setInterval(tick, 1000);
  setInterval(carregar, 15000);    // sincroniza com o servidor (situação dos alarmes, limpeza de dias anteriores)
  carregar();

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js').catch((e) => console.warn('SW:', e));
  }
}

iniciar();
