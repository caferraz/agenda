# Agenda de Compromissos

Aplicação **PWA/SPA** (instalável como app no Chrome/Edge) com backend em **Windows PowerShell 5.1**
e banco de dados em **arquivo JSON**. Não precisa instalar nada: roda em qualquer Windows 10/11.

## Como executar

1. Dê dois cliques em **`Agenda.exe`** (ou `iniciar.bat`, que faz o mesmo). Não abre nenhuma janela preta:
   a agenda passa a rodar **em segundo plano**, com um ícone 📅 ao lado do relógio do Windows.
2. Na primeira vez ele já se configura para **iniciar junto com o Windows**.
3. Abra a agenda em `http://localhost:8085` (ou clique no ícone). Opcional: no Chrome/Edge, **Instalar app**.
4. Use **🔔 Testar alarme** para conferir a janela e o som do alarme.

### Ícone ao lado do relógio (bandeja)

- **Clique** no ícone: abre a agenda. **Botão direito**: menu com *Abrir agenda*, *Testar alarme*,
  *Iniciar com o Windows* (liga/desliga), *Reiniciar servidor*, *Ver registro (log)* e *Sair*.
- **Vigia automático:** se o servidor parar por qualquer motivo, ele é reiniciado sozinho em poucos segundos.
- Abrir o `Agenda.exe` de novo não duplica nada: apenas abre a agenda no navegador.
- No Windows 11 o ícone pode ficar escondido na setinha **^**. Para deixá-lo sempre visível, arraste-o
  para a barra ou ative-o em *Configurações > Personalização > Barra de tarefas > Outros ícones da bandeja do sistema*.
- **Sair** desliga os alarmes até a agenda ser aberta de novo.

Diagnóstico: `iniciar-console.bat` roda o servidor numa janela de console, mostrando as mensagens
(feche antes o ícone da bandeja com *Sair*). O registro do modo em segundo plano fica em `dados/servidor.log`.

## Funcionalidades (premissas atendidas)

| Premissa | Como funciona |
|---|---|
| Título do agendamento | Campo obrigatório (até 120 caracteres) |
| Dia no calendário + horário inicial/final | Calendário mensal; dias anteriores ficam bloqueados; final precisa ser maior que o inicial |
| Aviso de conflito | Aviso em tempo real ao digitar os horários. Ao salvar, abre a janela **"Conflito de agendamento"** listando os compromissos coincidentes e pergunta se deseja **incluir mesmo assim** (ou salvar a alteração mesmo assim). Compromissos sobrepostos ficam marcados com "⚠️ conflito de horário" nas listas. Horários encostados (10:00–11:00 e 11:00–12:00) não conflitam. Na recorrência, datas com conflito continuam sendo puladas |
| Menu de tempo para aviso | **Padrão: 10 min antes.** Também: no horário, 1, 5, 15, 30, 45 min, 1 h, 2 h, 4 h, 1 dia antes |
| Aviso visual e sonoro | O **servidor** abre uma janela própria do Windows **sempre na frente de todas as outras** (mesmo com o navegador minimizado, em outra aba ou fechado), com faixa vermelha piscando e o som de alarme do Windows em repetição (até 2 min ou até clicar "OK, ciente"). Tem também o botão "Abrir agenda" |
| Adiar alarme | Na janela do alarme: **Adiar para 5, 2 ou 1 min antes** do início. Só aparecem as opções que ainda estão no futuro; dá para adiar várias vezes (ex.: 10 → 5 → 2 → 1). "OK, ciente" (ou Esc) encerra os alarmes daquele compromisso |
| Exclusão automática do dia anterior | O servidor apaga compromissos de datas anteriores a hoje a cada minuto e a cada requisição |
| Alterar/excluir só se não alarmado e não vencido | Botões desabilitados após o primeiro alarme ou após o horário de início; o servidor também bloqueia (HTTP 409) |
| Lista de compromissos cadastrados | Quadro com todos os compromissos; o **próximo a ser alarmado** fica destacado com o horário do alarme. Clicar na linha abre o compromisso para alterar ou excluir (se ainda permitido). O botão **🙈 Esconder vencidos / 👁 Mostrar vencidos** oculta (ou volta a exibir) os compromissos que já começaram, nesta lista e na do dia; a escolha fica salva no navegador. **Paginação** no rodapé: *Registros por página* editável (1–500, padrão 10, salvo no navegador), botões « ‹ › » e campo para digitar a página |
| Tema claro/escuro | Botão no topo; a escolha fica salva no navegador. Sem escolha, segue o tema do Windows |
| Recorrência (diária, semanal, mensal) | Botão 🔁 em compromissos ainda não iniciados; escolhe o tipo e o nº de repetições (1–60), com prévia das datas. Datas com conflito são ignoradas e informadas. Mensal em dia 31 usa o último dia do mês |

## Calendários do Outlook e do Google (importação)

Clique em **🔗 Calendários**, dê um nome (ex.: *Outlook Intecom*), cole o **link ICS/iCal** e escolha o aviso.
Os eventos dos **próximos 60 dias** passam a aparecer na agenda com o selo 📅 do calendário e ganham
alarme, adiamento, aviso no celular e detecção de conflito. A sincronização é automática **a cada 5 minutos**
(ou em *🔄 Sincronizar agora*).

- **Outlook (conta da empresa):** Outlook na Web ou novo Outlook › Configurações › Calendário › *Calendários
  compartilhados* › **Publicar um calendário** › "Pode exibir todos os detalhes" › copie o link **ICS**.
  Se a opção não existir, a publicação foi bloqueada pela TI.
- **Google Agenda:** Configurações › (sua agenda) › *Integrar agenda* › **Endereço secreto no formato iCal**.

Regras:
- **Link da reunião:** quando o evento tem link do **Teams**, **Google Meet**, **Zoom** ou **Webex** (no convite,
  no local ou na descrição), aparece o botão **🎥 Entrar na reunião** nas listas (até o fim do compromisso),
  na **janela de alarme** (abre o link e encerra o alarme) e na notificação do **celular** (botão e toque
  na notificação). Para o celular, o link só é enviado se "Mostrar o título" estiver ligado.
- Eventos importados são **somente leitura**: alterar/excluir/recorrência é feito no Outlook/Google.
- Eventos recorrentes são expandidos (diário, semanal, mensal — ex.: "2ª terça", "última sexta" —, anual,
  com exceções e ocorrências remarcadas). Fusos horários são convertidos para o horário deste computador.
- Eventos de **dia inteiro** (feriados, aniversários) são ignorados, pois não têm horário para alarmar.
- Eventos que já começaram no momento da importação entram como alarmados (não disparam atrasados).
- Se um link falhar, os eventos já importados dele são mantidos até a próxima sincronização bem-sucedida.
- **Exclusões:** a seção `"exclusoes"` de `dados/config.json` lista eventos importados que nunca entram na
  agenda. Exemplo em uso: `{ "titulo": "RESERVADO", "somenteRecorrentes": true, "calendarioId": null }`
  (título sem diferenciar maiúsculas; `somenteRecorrentes` = só ocorrências de séries; `calendarioId` vazio
  = todos os calendários). Vale a partir da próxima sincronização; para desfazer, remova a entrada.
- Os links funcionam como senha e ficam só em `dados/config.json`. Se o envio ao celular mostra o título,
  os títulos dos eventos importados também passam pelo ntfy.sh.

## Alertas no celular e smartwatch

No horário do alarme o servidor também publica uma notificação no **ntfy** (serviço gratuito, https://ntfy.sh).
O smartwatch recebe junto, pois espelha as notificações do celular.

1. Instale o app **ntfy** no celular (Android/iPhone).
2. Na agenda, clique em **📱 Celular**, copie o **tópico** (nome secreto gerado automaticamente) e, no app ntfy, toque em **+** e inscreva-se nele.
3. Clique em **Enviar teste**. No relógio, confira se o app ntfy está autorizado a mostrar notificações (app do relógio no celular).

Opções: ligar/desligar o envio, mostrar ou ocultar o título do compromisso (privacidade) e a prioridade
(Urgente = vibração insistente). **Gerar novo tópico** troca o nome secreto (será preciso se inscrever de novo).

**Adiar pelo celular/relógio (opcional):** a notificação pode trazer os botões *Lembrar 5 / 2 / 1 min antes*,
que falam direto com o servidor pela rede local. Requisitos: celular no mesmo Wi-Fi/rede do computador,
executar **`liberar-rede.bat` como administrador** uma única vez, marcar a opção em 📱 Celular escolhendo o
endereço do computador e reiniciar o `iniciar.bat`. Pela rede, o servidor aceita **somente** esse comando,
protegido por um código secreto; a agenda continua acessível apenas no próprio computador. Ao adiar pelo
celular, a janela de alarme do computador fecha sozinha.

> O título do compromisso passa pelo servidor público ntfy.sh. Se preferir, desmarque "Mostrar o título".
> A configuração fica em `dados/config.json`.

> O alarme depende só do servidor estar rodando, não do navegador. Se o servidor estava desligado no momento do aviso e o compromisso ainda não terminou, o alarme dispara assim que ele for iniciado.

## Estrutura

```
AgendaCompromissos/
├─ Agenda.exe               inicia a agenda em segundo plano (ícone na bandeja)
├─ bandeja.ps1              ícone da bandeja + vigia que mantém o servidor sempre no ar
├─ iniciar.bat              mesmo que abrir o Agenda.exe
├─ iniciar-console.bat      servidor com janela de console (diagnóstico)
├─ fonte/                   código-fonte e ícone do Agenda.exe (recompilar: ver comentário em Agenda.cs)
├─ servidor.ps1             servidor HTTP + API REST + regras de negócio + disparo dos alarmes
├─ alarme.ps1               janela de alarme do Windows (aberta pelo servidor; não executar manualmente)
├─ sincronizar.ps1          importa os calendários Outlook/Google (rodado pelo servidor a cada 5 min)
├─ dados/externos.json      resultado da última sincronização
├─ liberar-rede.bat         (opcional, como administrador) libera os botões de adiar no celular
├─ dados/config.json        configuração dos alertas no celular (criada automaticamente)
├─ dados/servidor.log       registro do servidor em segundo plano
├─ dados/compromissos.json  banco de dados (criado automaticamente)
└─ public/                  frontend PWA (index.html, app.js, styles.css, sw.js, manifest, ícone)
```

## API REST

| Método | Rota | Descrição |
|---|---|---|
| GET | `/api/compromissos` | Lista (após limpar dias anteriores) |
| POST | `/api/compromissos` | Cria `{titulo, data:"AAAA-MM-DD", inicio:"HH:MM", fim:"HH:MM", avisoMinutos, forcar?}`. Em conflito retorna 409 com `codigo:"conflito"`; reenvie com `forcar:true` para incluir mesmo assim |
| PUT | `/api/compromissos/{id}` | Altera (409 se já alarmado/vencido, ou em conflito sem `forcar:true`) |
| DELETE | `/api/compromissos/{id}` | Exclui (409 se já alarmado) |
| POST | `/api/compromissos/{id}/alarmar` | Marca como alarmado (encerra adiamentos) |
| POST | `/api/testar-alarme` | Abre uma janela de alarme de teste (não grava nada) |
| GET / POST | `/api/calendarios` | Lista (links mascarados + situação) / adiciona `{nome, url, avisoMinutos}` |
| PUT / DELETE | `/api/calendarios/{id}` | Ativa/desativa, renomeia, muda aviso / remove (e tira os eventos dele da agenda) |
| POST | `/api/calendarios/sincronizar` | Sincroniza agora |
| GET / PUT | `/api/celular` | Lê / altera a configuração dos alertas no celular (`novoTopico:true` gera outro tópico) |
| POST | `/api/celular/teste` | Envia uma notificação de teste ao celular |
| POST | `/api/celular/adiar?id=&n=&t=` | Usado pelo botão da notificação (único acesso permitido pela rede; exige o token) |
| POST | `/api/compromissos/{id}/adiar` | `{minutosAntes: 5\|2\|1}` → toca de novo faltando N minutos para o início |
| POST | `/api/compromissos/{id}/recorrencia` | `{tipo:"diaria"\|"semanal"\|"mensal", quantidade}` → `{criados, ignorados}` |

Erros retornam `{ "erro": "mensagem" }` (e `conflitos` no caso de 409 por conflito).
