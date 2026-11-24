<#
  Agenda de Compromissos - servidor HTTP + API REST
  Requisitos: apenas Windows PowerShell 5.1 (nativo do Windows). Sem instalações.
  Banco de dados: arquivo JSON em .\dados\compromissos.json

  Uso:  powershell -ExecutionPolicy Bypass -File .\servidor.ps1 [-Porta 8085] [-AbrirNavegador]
#>
param(
    [int]$Porta = 8085,
    [switch]$AbrirNavegador
)

$ErrorActionPreference = 'Stop'
$Raiz       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Publico    = [IO.Path]::GetFullPath((Join-Path $Raiz 'public'))
$PastaDados = Join-Path $Raiz 'dados'
$Arquivo    = Join-Path $PastaDados 'compromissos.json'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Inv        = [Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path $PastaDados)) { New-Item -ItemType Directory -Path $PastaDados | Out-Null }
if (-not (Test-Path $Arquivo))    { [IO.File]::WriteAllText($Arquivo, '[]', $Utf8) }

$TiposMime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.webmanifest' = 'application/manifest+json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
    '.ics'  = 'text/calendar; charset=utf-8'
}

# ---------------------------------------------------------------- utilidades
function Get-Hoje { (Get-Date).ToString('yyyy-MM-dd', $Inv) }

function Get-Minutos([string]$hora) {
    $p = $hora.Split(':')
    return ([int]$p[0]) * 60 + [int]$p[1]
}

function Get-DataHora([string]$data, [string]$hora) {
    [datetime]::ParseExact("$data $hora", 'yyyy-MM-dd HH:mm', $Inv)
}

function ConvertTo-Compromisso($o) {
    [pscustomobject]@{
        id           = [string]$o.id
        titulo       = [string]$o.titulo
        data         = [string]$o.data
        inicio       = [string]$o.inicio
        fim          = [string]$o.fim
        avisoMinutos = [int]$o.avisoMinutos
        alarmado     = [bool]$o.alarmado
        serieId      = if ($o.serieId) { [string]$o.serieId } else { $null }
        # alarme adiado: avisar de novo faltando N minutos (5, 2 ou 1) para o início
        adiadoPara   = if ($null -ne $o.adiadoPara -and "$($o.adiadoPara)" -ne '') { [int]$o.adiadoPara } else { $null }
        criadoEm     = [string]$o.criadoEm
        # eventos importados de calendários externos (Outlook/Google): somente leitura
        calendarioId = if ($o.calendarioId) { [string]$o.calendarioId } else { $null }
        origem       = if ($o.origem) { [string]$o.origem } else { $null }
        # link para entrar na reunião online (Teams, Meet, Zoom...), vindo do Outlook/Google
        link         = Get-LinkSeguro $o.link
    }
}

# Aceita só endereços https sem espaços/aspas (o link vem de fonte externa e vira botão na tela)
function Get-LinkSeguro($u) {
    $s = [string]$u
    if ($s.Length -le 2048 -and $s -match '^https://[^\s"''<>\\]+$') { return $s }
    return $null
}

$OpcoesAdiar = @(5, 2, 1)
$AvisoPadrao = 10

function Test-Vencido($c) { (Get-DataHora $c.data $c.inicio) -le (Get-Date) }

# ---------------------------------------------------------------- alarmes (disparados pelo servidor)
# O navegador não consegue se sobrepor às outras janelas nem tocar som confiavelmente em segundo plano.
# Por isso o servidor abre uma janela própria do Windows (alarme.ps1), sempre na frente, com som.
$AlarmeScript = Join-Path $Raiz 'alarme.ps1'
$Disparados = @{}

function Show-AlarmeDesktop($c, [switch]$Teste) {
    $o = @{ id = $c.id; titulo = $c.titulo; data = $c.data; inicio = $c.inicio; fim = $c.fim; teste = [bool]$Teste; link = (Get-LinkSeguro $c.link) }
    $b64 = [Convert]::ToBase64String($Utf8.GetBytes((ConvertTo-Json -InputObject $o -Compress)))
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$AlarmeScript`"", '-Dados', $b64, '-Porta', $Porta)
    Write-Host ("[{0}] ALARME: {1} ({2} {3}-{4})" -f (Get-Date -Format 'HH:mm:ss'), $c.titulo, $c.data, $c.inicio, $c.fim) -ForegroundColor Yellow
}

# Momento do próximo alarme: aviso inicial (avisoMinutos) ou adiamento (adiadoPara); $null se não houver
function Get-ProximoAlarme($c) {
    $ini = Get-DataHora $c.data $c.inicio
    if (-not $c.alarmado) { return $ini.AddMinutes(-$c.avisoMinutos) }
    if ($null -ne $c.adiadoPara) { return $ini.AddMinutes(-$c.adiadoPara) }
    return $null
}

function Invoke-VerificarAlarmes {
    $lista = Get-Compromissos
    $agora = Get-Date
    $mudou = $false
    foreach ($c in $lista) {
        $t = Get-ProximoAlarme $c
        if ($null -eq $t -or $agora -lt $t) { continue }
        $chave = '{0}:{1}:{2}' -f $c.id, $c.alarmado, $c.adiadoPara
        if (-not $script:Disparados.ContainsKey($chave)) {
            $script:Disparados[$chave] = $true
            # se o servidor estava desligado e o compromisso já terminou, só marca como alarmado
            if ($agora -lt (Get-DataHora $c.data $c.fim)) {
                Show-AlarmeDesktop $c
                Send-AlertaCelular $c
            }
        }
        $c.alarmado = $true
        $c.adiadoPara = $null
        $mudou = $true
    }
    if ($mudou) { Save-Compromissos $lista }
}

# Adiamento (usado pela janela do Windows, pela página e pelo botão da notificação no celular)
function Invoke-AdiarCompromisso($lista, $item, [int]$n) {
    if ($OpcoesAdiar -notcontains $n) { return 'Adiamento inválido: use 5, 2 ou 1 minuto antes do início.' }
    if ((Get-DataHora $item.data $item.inicio).AddMinutes(-$n) -le (Get-Date)) {
        return "Não dá mais para adiar para $n minuto(s) antes: esse momento já passou."
    }
    $item.alarmado = $true
    $item.adiadoPara = $n
    Save-Compromissos $lista
    return $null
}

# ---------------------------------------------------------------- alertas no celular / smartwatch (ntfy)
# O servidor publica uma notificação no ntfy (https://ntfy.sh). O app "ntfy" no celular, inscrito
# no mesmo tópico, recebe e o smartwatch espelha a notificação do celular.
$ArquivoConfig = Join-Path $PastaDados 'config.json'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:RedeLiberada = $false   # true quando o servidor aceita conexões da rede local (botões de adiar no celular)

function New-Segredo([int]$bytes) {
    $b = New-Object byte[] $bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# dados\config.json guarda várias seções (celular, calendarios); cada gravação altera só a sua seção
function Read-ConfigArquivo {
    if (Test-Path $ArquivoConfig) { try { return ([IO.File]::ReadAllText($ArquivoConfig, $Utf8) | ConvertFrom-Json) } catch { } }
    return [pscustomobject]@{}
}
function Save-ConfigSecao([string]$secao, $valor) {
    $cfg = Read-ConfigArquivo
    $cfg | Add-Member -Force -NotePropertyName $secao -NotePropertyValue $valor
    [IO.File]::WriteAllText($ArquivoConfig, (ConvertTo-Json -InputObject $cfg -Depth 6), $Utf8)
}

function Save-ConfigCelular($cfg) { Save-ConfigSecao 'celular' $cfg }

function Get-ConfigCelular {
    $lido = (Read-ConfigArquivo).celular
    $o = [ordered]@{
        ativo = $true; servidor = 'https://ntfy.sh'; topico = ''; prioridade = 5; mostrarTitulo = $true
        adiarPeloCelular = $false; enderecoRede = ''; token = ''
    }
    if ($lido) { foreach ($k in @($o.Keys)) { if ($null -ne $lido.$k) { $o[$k] = $lido.$k } } }
    $novo = $false
    if (-not $o.topico) { $o.topico = 'agenda-' + (New-Segredo 10); $novo = $true }   # nome secreto e aleatório
    if (-not $o.token)  { $o.token = New-Segredo 16; $novo = $true }                 # protege o "adiar" vindo da rede
    $cfg = [pscustomobject]$o
    if ($novo) { Save-ConfigCelular $cfg }
    return $cfg
}

function Send-Ntfy($cfg, [string]$titulo, [string]$mensagem, [int]$prioridade, $acoes, [string]$aoTocar) {
    $msg = [ordered]@{ topic = $cfg.topico; title = $titulo; message = $mensagem; priority = $prioridade; tags = @('alarm_clock') }
    if ($aoTocar) { $msg.click = $aoTocar }      # tocar na notificação abre o link (ex.: reunião do Teams)
    if (@($acoes).Count -gt 0) { $msg.actions = [object[]]@($acoes) }
    $corpo = $Utf8.GetBytes((ConvertTo-Json -InputObject $msg -Depth 5 -Compress))
    Invoke-RestMethod -Method Post -Uri ($cfg.servidor.TrimEnd('/') + '/') -Body $corpo `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec 8 | Out-Null
}

function Send-AlertaCelular($c) {
    try {
        $cfg = Get-ConfigCelular
        if (-not $cfg.ativo) { return }
        $ini = Get-DataHora $c.data $c.inicio
        $min = [Math]::Round(($ini - (Get-Date)).TotalMinutes)
        $falta = if ($min -gt 0) { "Começa em $min min" } elseif ($min -eq 0) { 'Começa agora' } else { "Começou há $(-$min) min" }
        $titulo = if ($cfg.mostrarTitulo) { [string]$c.titulo } else { 'Compromisso agendado' }
        $texto = "$falta · $($ini.ToString('dd/MM', $Inv)) das $($c.inicio) às $($c.fim)"
        $acoes = @()
        # link da reunião: só vai ao celular (via ntfy.sh) quando o título também pode ir
        $link = if ($cfg.mostrarTitulo) { Get-LinkSeguro $c.link } else { $null }
        if ($link) { $acoes += [ordered]@{ action = 'view'; label = 'Entrar na reunião'; url = $link; clear = $true } }
        if ($cfg.adiarPeloCelular -and $cfg.enderecoRede -and $script:RedeLiberada) {
            foreach ($n in $OpcoesAdiar) {
                if ($acoes.Count -ge 3) { break }          # o ntfy aceita no máximo 3 botões
                if ($ini.AddMinutes(-$n) -gt (Get-Date)) {
                    $acoes += [ordered]@{
                        action = 'http'; label = "Lembrar $n min antes"; method = 'POST'; clear = $true
                        url = "http://$($cfg.enderecoRede):$Porta/api/celular/adiar?id=$($c.id)&n=$n&t=$($cfg.token)"
                    }
                }
            }
        }
        Send-Ntfy $cfg ([char]0x23F0 + ' ' + $titulo) $texto ([int]$cfg.prioridade) $acoes $link
        Write-Host '           -> alerta enviado ao celular' -ForegroundColor DarkYellow
    }
    catch { Write-Warning "Falha ao enviar alerta ao celular: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- calendários externos (Outlook / Google via link ICS)
# O sincronizar.ps1 roda em segundo plano, baixa os links e grava dados\externos.json; o servidor incorpora
# as ocorrências na agenda (somente leitura), mantendo o estado de alarme/adiamento de cada uma.
$ArqExternos = Join-Path $PastaDados 'externos.json'
$SincScript = Join-Path $Raiz 'sincronizar.ps1'
$IntervaloSincMin = 5
$script:procSinc = $null
$script:ultimaSinc = [datetime]::MinValue
$script:externosLidoEm = [datetime]::MinValue
$script:StatusCal = @{}

function Get-Calendarios { @((Read-ConfigArquivo).calendarios | Where-Object { $_ }) }
function Save-Calendarios($lista) { Save-ConfigSecao 'calendarios' ([object[]]@($lista)) }

function Test-Sincronizando { [bool]($script:procSinc -and -not $script:procSinc.HasExited) }

function Start-Sincronizacao {
    if (Test-Sincronizando) { return $false }
    $script:ultimaSinc = Get-Date
    if (@(Get-Calendarios | Where-Object { $_.ativo }).Count -eq 0) { return $false }
    $script:procSinc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$SincScript`"")
    return $true
}

function Remove-ItensCalendario([string]$calId) {
    $lista = Get-Compromissos
    $rem = @($lista | Where-Object { $_.calendarioId -eq $calId })
    if ($rem.Count) { foreach ($r in $rem) { $lista.Remove($r) }; Save-Compromissos $lista }
}

# incorpora o resultado da última sincronização (só quando o arquivo muda)
function Update-Externos {
    if (-not (Test-Path $ArqExternos)) { return }
    $mod = (Get-Item $ArqExternos).LastWriteTimeUtc
    if ($mod -le $script:externosLidoEm) { return }
    $script:externosLidoEm = $mod
    $res = [IO.File]::ReadAllText($ArqExternos, $Utf8) | ConvertFrom-Json
    $script:StatusCal = @{}
    foreach ($s in @($res.calendarios)) { if ($s) { $script:StatusCal[[string]$s.id] = $s } }

    $ativos = @(Get-Calendarios | Where-Object { $_.ativo } | ForEach-Object { [string]$_.id })
    $okIds = @($res.calendarios | Where-Object { $_ -and $_.ok -and $ativos -contains [string]$_.id } | ForEach-Object { [string]$_.id })
    $lista = Get-Compromissos
    $existentes = @{}
    foreach ($c in $lista) { if ($c.calendarioId) { $existentes[$c.id] = $c } }
    $vistos = @{}
    $agora = Get-Date
    $hoje = Get-Hoje
    foreach ($e in @($res.eventos)) {
        if (-not $e -or $okIds -notcontains [string]$e.calendarioId -or $e.data -lt $hoje) { continue }
        $vistos[$e.id] = $true
        $c = $existentes[$e.id]
        if ($c) {
            $c.titulo = [string]$e.titulo; $c.fim = [string]$e.fim; $c.origem = [string]$e.origem
            $c.link = Get-LinkSeguro $e.link
            if (-not $c.alarmado) { $c.avisoMinutos = [int]$e.avisoMinutos }
        }
        else {
            $novo = ConvertTo-Compromisso @{
                id = $e.id; titulo = $e.titulo; data = $e.data; inicio = $e.inicio; fim = $e.fim
                avisoMinutos = [int]$e.avisoMinutos; alarmado = $false; serieId = $null; adiadoPara = $null
                criadoEm = $agora.ToString('s'); calendarioId = $e.calendarioId; origem = $e.origem
                link = $e.link
            }
            # já começou: entra como alarmado, para não disparar alarmes atrasados na importação
            if ((Get-DataHora $novo.data $novo.inicio) -le $agora) { $novo.alarmado = $true }
            [void]$lista.Add($novo)
        }
    }
    # remove o que sumiu da origem (só de calendários lidos com sucesso) e o de calendários removidos/desativados
    $rem = @($lista | Where-Object {
        $_.calendarioId -and (($ativos -notcontains $_.calendarioId) -or ($okIds -contains $_.calendarioId -and -not $vistos.ContainsKey($_.id)))
    })
    foreach ($r in $rem) { $lista.Remove($r) }
    Save-Compromissos $lista
    $n = @($res.eventos).Count
    Write-Host ("[{0}] Calendários externos sincronizados: {1} ocorrência(s)." -f (Get-Date -Format 'HH:mm:ss'), $n)
}

function Hide-Url([string]$u) {
    if ($u -match '^(\w+://[^/]+)') { $base = $Matches[1] } else { $base = '' }
    $fim = if ($u.Length -gt 6) { $u.Substring($u.Length - 6) } else { '' }
    return "$base/…$fim"
}

function Get-EnderecosRede {
    try {
        @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            ForEach-Object { @{ ip = $_.IPAddress; rede = $_.InterfaceAlias } })
    } catch { @() }
}

function Get-Compromissos {
    $texto = [IO.File]::ReadAllText($Arquivo, $Utf8)
    $lista = New-Object System.Collections.ArrayList
    if ($texto.Trim()) {
        foreach ($c in (ConvertFrom-Json $texto)) { [void]$lista.Add((ConvertTo-Compromisso $c)) }
    }
    return , $lista
}

function Save-Compromissos($lista) {
    $ordenada = @($lista | Sort-Object data, inicio)
    $json = ConvertTo-Json -InputObject ([object[]]$ordenada) -Depth 5
    if (-not $json) { $json = '[]' }
    $tmp = "$Arquivo.tmp"
    [IO.File]::WriteAllText($tmp, $json, $Utf8)
    Move-Item -Force -LiteralPath $tmp -Destination $Arquivo
}

# Exclui automaticamente compromissos de dias anteriores
function Remove-Vencidos {
    $lista = Get-Compromissos
    $hoje = Get-Hoje
    $antigos = @($lista | Where-Object { $_.data -lt $hoje })
    if ($antigos.Count -gt 0) {
        foreach ($a in $antigos) { $lista.Remove($a) }
        Save-Compromissos $lista
        Write-Host ("[{0}] Limpeza automatica: {1} compromisso(s) de dias anteriores excluido(s)." -f (Get-Date -Format 'HH:mm:ss'), $antigos.Count)
    }
    return , $lista
}

function Find-Conflitos($lista, [string]$data, [string]$inicio, [string]$fim, [string]$ignorarId) {
    $ini = Get-Minutos $inicio
    $fi  = Get-Minutos $fim
    $r = @($lista | Where-Object {
        $_.data -eq $data -and $_.id -ne $ignorarId -and
        $ini -lt (Get-Minutos $_.fim) -and $fi -gt (Get-Minutos $_.inicio)
    })
    return , $r
}

function Test-Dados($b) {
    if (-not $b) { return 'Corpo da requisicao invalido.' }
    $titulo = ([string]$b.titulo).Trim()
    if (-not $titulo)            { return 'Informe o título do compromisso.' }
    if ($titulo.Length -gt 120)  { return 'O título deve ter no máximo 120 caracteres.' }
    if ([string]$b.data -notmatch '^\d{4}-\d{2}-\d{2}$') { return 'Data inválida.' }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$b.data, 'yyyy-MM-dd', $Inv, 'None', [ref]$d)) { return 'Data inválida.' }
    $rxHora = '^([01]\d|2[0-3]):[0-5]\d$'
    if ([string]$b.inicio -notmatch $rxHora) { return 'Horário inicial inválido.' }
    if ([string]$b.fim    -notmatch $rxHora) { return 'Horário final inválido.' }
    if ((Get-Minutos $b.fim) -le (Get-Minutos $b.inicio)) { return 'O horário final deve ser maior que o horário inicial.' }
    $aviso = 0
    if ($null -eq $b.avisoMinutos -or "$($b.avisoMinutos)" -eq '') { $b | Add-Member -Force NoteProperty avisoMinutos $AvisoPadrao }
    if (-not [int]::TryParse([string]$b.avisoMinutos, [ref]$aviso) -or $aviso -lt 0 -or $aviso -gt 1440) {
        return 'Tempo de aviso inválido (0 a 1440 minutos).'
    }
    $hoje = Get-Hoje
    if ([string]$b.data -lt $hoje) { return 'Não é possível agendar em dias anteriores.' }
    if ((Get-DataHora $b.data $b.fim) -le (Get-Date)) { return 'O horário final já passou.' }
    return $null
}

function Format-Conflito($c) { "'{0}' ({1} - {2})" -f $c.titulo, $c.inicio, $c.fim }

# ---------------------------------------------------------------- HTTP
function Send-Resposta($ctx, [int]$status, [byte[]]$bytes, [string]$tipo) {
    $res = $ctx.Response
    $res.StatusCode = $status
    $res.ContentType = $tipo
    $res.Headers['Cache-Control'] = 'no-cache'
    $res.ContentLength64 = $bytes.Length
    if ($bytes.Length -gt 0) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
    $res.OutputStream.Close()
}

function Send-Json($ctx, [int]$status, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 6
    if ($null -eq $json) { $json = 'null' }
    Send-Resposta $ctx $status ($Utf8.GetBytes($json)) 'application/json; charset=utf-8'
}

function Send-Erro($ctx, [int]$status, [string]$msg, $extra) {
    $o = @{ erro = $msg }
    if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
    Send-Json $ctx $status $o
}

function Read-Corpo($req) {
    $sr = New-Object System.IO.StreamReader($req.InputStream, $Utf8)
    $t = $sr.ReadToEnd(); $sr.Close()
    if (-not $t.Trim()) { return $null }
    return (ConvertFrom-Json $t)
}

function Send-Arquivo($ctx, [string]$caminho) {
    if ($caminho -eq '/' -or $caminho -eq '') { $caminho = '/index.html' }
    $rel = [Uri]::UnescapeDataString($caminho.TrimStart('/')).Replace('/', '\')
    $full = [IO.Path]::GetFullPath((Join-Path $Publico $rel))
    if (-not $full.StartsWith($Publico, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Send-Resposta $ctx 404 ($Utf8.GetBytes('Nao encontrado')) 'text/plain; charset=utf-8'; return
    }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    $tipo = $TiposMime[$ext]; if (-not $tipo) { $tipo = 'application/octet-stream' }
    Send-Resposta $ctx 200 ([IO.File]::ReadAllBytes($full)) $tipo
}

# ---------------------------------------------------------------- API
function Invoke-Api($ctx) {
    $req = $ctx.Request
    $m = $req.HttpMethod
    $p = $req.Url.AbsolutePath.TrimEnd('/')
    if ($p -eq '/api/compromissos' -and $m -eq 'GET') { try { Update-Externos } catch { } }
    $lista = Remove-Vencidos

    # GET /api/compromissos
    if ($p -eq '/api/compromissos' -and $m -eq 'GET') {
        Send-Json $ctx 200 ([object[]]@($lista | Sort-Object data, inicio)); return
    }

    # GET /api/calendarios  -> calendários externos cadastrados (links mascarados) e situação
    if ($p -eq '/api/calendarios' -and $m -eq 'GET') {
        try { Update-Externos } catch { }
        $out = @(foreach ($c in @(Get-Calendarios)) {
            @{ id = $c.id; nome = $c.nome; url = (Hide-Url $c.url); ativo = [bool]$c.ativo
               avisoMinutos = [int]$c.avisoMinutos; status = $script:StatusCal[[string]$c.id] }
        })
        Send-Json $ctx 200 @{ sincronizando = (Test-Sincronizando); intervaloMin = $IntervaloSincMin; calendarios = [object[]]$out }; return
    }

    # POST /api/calendarios  { nome, url, avisoMinutos }
    if ($p -eq '/api/calendarios' -and $m -eq 'POST') {
        $b = Read-Corpo $req
        $nome = ([string]$b.nome).Trim(); $url = ([string]$b.url).Trim()
        if (-not $nome -or $nome.Length -gt 60) { Send-Erro $ctx 400 'Informe um nome para o calendário (até 60 caracteres).'; return }
        if ($url -notmatch '^(https?|webcals?)://\S+$') { Send-Erro $ctx 400 'Link inválido: cole o endereço ICS/iCal completo (https://... ou webcal://...).'; return }
        $aviso = 10
        if ($null -ne $b.avisoMinutos -and (-not [int]::TryParse([string]$b.avisoMinutos, [ref]$aviso) -or $aviso -lt 0 -or $aviso -gt 1440)) {
            Send-Erro $ctx 400 'Tempo de aviso inválido.'; return
        }
        $cals = @(Get-Calendarios)
        if ($cals | Where-Object { $_.url -eq $url }) { Send-Erro $ctx 409 'Este link já está cadastrado.'; return }
        $novo = [pscustomobject][ordered]@{ id = (New-Segredo 4); nome = $nome; url = $url; ativo = $true; avisoMinutos = $aviso }
        Save-Calendarios ($cals + $novo)
        if (Test-Sincronizando) { $script:ultimaSinc = [datetime]::MinValue } else { [void](Start-Sincronizacao) }
        Send-Json $ctx 201 @{ id = $novo.id }; return
    }

    # POST /api/calendarios/sincronizar  -> sincroniza agora
    if ($p -eq '/api/calendarios/sincronizar' -and $m -eq 'POST') {
        Send-Json $ctx 200 @{ iniciado = (Start-Sincronizacao); sincronizando = (Test-Sincronizando) }; return
    }

    # PUT / DELETE /api/calendarios/{id}
    if ($p -match '^/api/calendarios/([0-9a-f]{8})$') {
        $calId = $Matches[1]
        $cals = @(Get-Calendarios)
        $cal = $cals | Where-Object { $_.id -eq $calId } | Select-Object -First 1
        if (-not $cal) { Send-Erro $ctx 404 'Calendário não encontrado.'; return }
        if ($m -eq 'DELETE') {
            Save-Calendarios @($cals | Where-Object { $_.id -ne $calId })
            Remove-ItensCalendario $calId
            Send-Json $ctx 200 @{ ok = $true }; return
        }
        if ($m -eq 'PUT') {
            $b = Read-Corpo $req
            if ($null -ne $b.ativo) { $cal.ativo = [bool]$b.ativo }
            if ($b.nome -and ([string]$b.nome).Trim()) { $cal.nome = ([string]$b.nome).Trim() }
            $aviso = 0
            if ($null -ne $b.avisoMinutos -and [int]::TryParse([string]$b.avisoMinutos, [ref]$aviso) -and $aviso -ge 0 -and $aviso -le 1440) {
                $cal | Add-Member -Force NoteProperty avisoMinutos $aviso
            }
            Save-Calendarios $cals
            if (-not $cal.ativo) { Remove-ItensCalendario $calId }
            else { if (Test-Sincronizando) { $script:ultimaSinc = [datetime]::MinValue } else { [void](Start-Sincronizacao) } }
            Send-Json $ctx 200 @{ ok = $true }; return
        }
    }

    # GET /api/celular  -> configuração dos alertas no celular (sem o token)
    if ($p -eq '/api/celular' -and $m -eq 'GET') {
        $cfg = Get-ConfigCelular
        Send-Json $ctx 200 @{
            ativo = [bool]$cfg.ativo; servidor = $cfg.servidor; topico = $cfg.topico; prioridade = [int]$cfg.prioridade
            mostrarTitulo = [bool]$cfg.mostrarTitulo; adiarPeloCelular = [bool]$cfg.adiarPeloCelular
            enderecoRede = $cfg.enderecoRede; redeLiberada = $script:RedeLiberada; porta = $Porta
            enderecos = [object[]](Get-EnderecosRede)
        }; return
    }

    # PUT /api/celular  -> altera a configuração  { ativo, prioridade, mostrarTitulo, adiarPeloCelular, enderecoRede, novoTopico }
    if ($p -eq '/api/celular' -and $m -eq 'PUT') {
        $b = Read-Corpo $req
        if (-not $b) { Send-Erro $ctx 400 'Corpo da requisição inválido.'; return }
        $cfg = Get-ConfigCelular
        if ($null -ne $b.ativo)            { $cfg.ativo = [bool]$b.ativo }
        if ($null -ne $b.mostrarTitulo)    { $cfg.mostrarTitulo = [bool]$b.mostrarTitulo }
        if ($null -ne $b.adiarPeloCelular) { $cfg.adiarPeloCelular = [bool]$b.adiarPeloCelular }
        if ($null -ne $b.prioridade) {
            $pr = 0
            if (-not [int]::TryParse([string]$b.prioridade, [ref]$pr) -or $pr -lt 1 -or $pr -gt 5) { Send-Erro $ctx 400 'Prioridade deve ser de 1 a 5.'; return }
            $cfg.prioridade = $pr
        }
        if ($null -ne $b.enderecoRede) {
            $ip = ([string]$b.enderecoRede).Trim()
            if ($ip -and $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Send-Erro $ctx 400 'Endereço de rede inválido.'; return }
            $cfg.enderecoRede = $ip
        }
        if ([bool]$b.novoTopico) { $cfg.topico = 'agenda-' + (New-Segredo 10) }
        Save-ConfigCelular $cfg
        Send-Json $ctx 200 @{ ok = $true; topico = $cfg.topico }; return
    }

    # POST /api/celular/teste  -> envia uma notificação de teste ao celular
    if ($p -eq '/api/celular/teste' -and $m -eq 'POST') {
        $cfg = Get-ConfigCelular
        try {
            Send-Ntfy $cfg ([char]0x2705 + ' Agenda de Compromissos') 'Teste: se você está vendo esta mensagem, os alertas no celular estão funcionando.' ([int]$cfg.prioridade) @()
            Send-Json $ctx 200 @{ ok = $true }
        }
        catch { Send-Erro $ctx 502 ('Não foi possível enviar ao ntfy: ' + $_.Exception.Message) }
        return
    }

    # POST /api/celular/adiar?id=..&n=..&t=token  -> botão "Lembrar N min antes" da notificação no celular
    if ($p -eq '/api/celular/adiar' -and $m -eq 'POST') {
        $q = $req.QueryString
        $cfg = Get-ConfigCelular
        if (-not $q['t'] -or $q['t'] -ne $cfg.token) { Send-Erro $ctx 403 'Acesso negado.'; return }
        $item = $lista | Where-Object { $_.id -eq $q['id'] } | Select-Object -First 1
        if (-not $item) { Send-Erro $ctx 404 'Compromisso não encontrado.'; return }
        $n = 0; [void][int]::TryParse([string]$q['n'], [ref]$n)
        $erro = Invoke-AdiarCompromisso $lista $item $n
        if ($erro) { Send-Erro $ctx 409 $erro; return }
        Write-Host ("[{0}] Adiado pelo celular: {1} -> {2} min antes" -f (Get-Date -Format 'HH:mm:ss'), $item.titulo, $n) -ForegroundColor Yellow
        Send-Json $ctx 200 @{ ok = $true }; return
    }

    # POST /api/testar-alarme  -> abre a janela de alarme de teste (não grava nada)
    if ($p -eq '/api/testar-alarme' -and $m -eq 'POST') {
        $ini = (Get-Date).AddMinutes(10)
        Show-AlarmeDesktop ([pscustomobject]@{
            id = ''; titulo = 'Teste de alarme'; data = $ini.ToString('yyyy-MM-dd', $Inv)
            inicio = $ini.ToString('HH:mm', $Inv); fim = $ini.AddMinutes(30).ToString('HH:mm', $Inv)
        }) -Teste
        Send-Json $ctx 200 @{ ok = $true }; return
    }

    # POST /api/compromissos
    if ($p -eq '/api/compromissos' -and $m -eq 'POST') {
        $b = Read-Corpo $req
        $erro = Test-Dados $b
        if ($erro) { Send-Erro $ctx 400 $erro; return }
        # conflito: recusa, a menos que o usuário tenha confirmado "incluir mesmo assim" (forcar = true)
        $conf = Find-Conflitos $lista $b.data $b.inicio $b.fim ''
        if ($conf.Count -gt 0 -and -not [bool]$b.forcar) {
            Send-Erro $ctx 409 ("Conflito de agendamento com: " + (($conf | ForEach-Object { Format-Conflito $_ }) -join ', ')) @{ codigo = 'conflito'; conflitos = [object[]]$conf }
            return
        }
        $novo = ConvertTo-Compromisso @{
            id = [guid]::NewGuid().ToString(); titulo = ([string]$b.titulo).Trim(); data = $b.data
            inicio = $b.inicio; fim = $b.fim; avisoMinutos = [int]$b.avisoMinutos; alarmado = $false
            serieId = $null; adiadoPara = $null; criadoEm = (Get-Date).ToString('s')
        }
        [void]$lista.Add($novo)
        Save-Compromissos $lista
        Send-Json $ctx 201 $novo; return
    }

    if ($p -match '^/api/compromissos/([0-9a-fA-F-]{36})(?:/(alarmar|adiar|recorrencia))?$') {
        $id = $Matches[1]; $acao = $Matches[2]
        $item = $lista | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $item) { Send-Erro $ctx 404 'Compromisso não encontrado (pode ter sido excluído).'; return }
        if ($item.calendarioId -and $acao -ne 'alarmar' -and $acao -ne 'adiar') {
            Send-Erro $ctx 409 "Evento importado de '$($item.origem)': altere ou exclua na agenda de origem."; return
        }

        # PUT /api/compromissos/{id}
        if (-not $acao -and $m -eq 'PUT') {
            if ($item.alarmado) { Send-Erro $ctx 409 'Este compromisso já foi alarmado e não pode mais ser alterado.'; return }
            if (Test-Vencido $item) { Send-Erro $ctx 409 'Este compromisso já está vencido e não pode mais ser alterado.'; return }
            $b = Read-Corpo $req
            $erro = Test-Dados $b
            if ($erro) { Send-Erro $ctx 400 $erro; return }
            $conf = Find-Conflitos $lista $b.data $b.inicio $b.fim $id
            if ($conf.Count -gt 0 -and -not [bool]$b.forcar) {
                Send-Erro $ctx 409 ("Conflito de agendamento com: " + (($conf | ForEach-Object { Format-Conflito $_ }) -join ', ')) @{ codigo = 'conflito'; conflitos = [object[]]$conf }
                return
            }
            $item.titulo = ([string]$b.titulo).Trim(); $item.data = $b.data
            $item.inicio = $b.inicio; $item.fim = $b.fim; $item.avisoMinutos = [int]$b.avisoMinutos
            Save-Compromissos $lista
            Send-Json $ctx 200 $item; return
        }

        # DELETE /api/compromissos/{id}
        if (-not $acao -and $m -eq 'DELETE') {
            if ($item.alarmado) { Send-Erro $ctx 409 'Este compromisso já foi alarmado e não pode mais ser excluído.'; return }
            if (Test-Vencido $item) { Send-Erro $ctx 409 'Este compromisso já está vencido e não pode mais ser excluído.'; return }
            $lista.Remove($item)
            Save-Compromissos $lista
            Send-Json $ctx 200 @{ ok = $true }; return
        }

        # POST /api/compromissos/{id}/alarmar
        if ($acao -eq 'alarmar' -and $m -eq 'POST') {
            $item.alarmado = $true
            $item.adiadoPara = $null
            Save-Compromissos $lista
            Send-Json $ctx 200 $item; return
        }

        # POST /api/compromissos/{id}/adiar  { minutosAntes: 5 | 2 | 1 }
        if ($acao -eq 'adiar' -and $m -eq 'POST') {
            $b = Read-Corpo $req
            $n = 0
            if (-not $b -or -not [int]::TryParse([string]$b.minutosAntes, [ref]$n)) {
                Send-Erro $ctx 400 'Adiamento inválido: use 5, 2 ou 1 minuto antes do início.'; return
            }
            $erro = Invoke-AdiarCompromisso $lista $item $n
            if ($erro) { Send-Erro $ctx $(if ($OpcoesAdiar -contains $n) { 409 } else { 400 }) $erro; return }
            Send-Json $ctx 200 $item; return
        }

        # POST /api/compromissos/{id}/recorrencia  { tipo: diaria|semanal|mensal, quantidade: N }
        if ($acao -eq 'recorrencia' -and $m -eq 'POST') {
            if ((Get-DataHora $item.data $item.inicio) -le (Get-Date)) {
                Send-Erro $ctx 409 'Só é possível criar recorrência de compromissos ainda não vencidos.'; return
            }
            $b = Read-Corpo $req
            $tipo = [string]$b.tipo
            if (@('diaria', 'semanal', 'mensal') -notcontains $tipo) { Send-Erro $ctx 400 'Tipo de recorrência inválido.'; return }
            $qtd = 0
            if (-not [int]::TryParse([string]$b.quantidade, [ref]$qtd) -or $qtd -lt 1 -or $qtd -gt 60) {
                Send-Erro $ctx 400 'Quantidade de repetições deve ser entre 1 e 60.'; return
            }
            if (-not $item.serieId) { $item.serieId = $item.id }
            $base = [datetime]::ParseExact($item.data, 'yyyy-MM-dd', $Inv)
            $criados = New-Object System.Collections.ArrayList
            $ignorados = New-Object System.Collections.ArrayList
            for ($i = 1; $i -le $qtd; $i++) {
                switch ($tipo) {
                    'diaria'  { $d = $base.AddDays($i) }
                    'semanal' { $d = $base.AddDays(7 * $i) }
                    'mensal'  { $d = $base.AddMonths($i) }   # dia 31 vira último dia do mês
                }
                $ds = $d.ToString('yyyy-MM-dd', $Inv)
                $conf = Find-Conflitos $lista $ds $item.inicio $item.fim ''
                if ($conf.Count -gt 0) {
                    [void]$ignorados.Add(@{ data = $ds; motivo = 'Conflito com ' + (($conf | ForEach-Object { Format-Conflito $_ }) -join ', ') })
                    continue
                }
                $novo = ConvertTo-Compromisso @{
                    id = [guid]::NewGuid().ToString(); titulo = $item.titulo; data = $ds
                    inicio = $item.inicio; fim = $item.fim; avisoMinutos = $item.avisoMinutos; alarmado = $false
                    serieId = $item.serieId; criadoEm = (Get-Date).ToString('s')
                }
                [void]$lista.Add($novo); [void]$criados.Add($novo)
            }
            Save-Compromissos $lista
            Send-Json $ctx 201 @{ criados = [object[]]$criados.ToArray(); ignorados = [object[]]$ignorados.ToArray() }; return
        }
    }

    Send-Erro $ctx 404 'Rota não encontrada.'
}

function Invoke-Requisicao($ctx) {
    try {
        $caminho = $ctx.Request.Url.AbsolutePath
        # Pela rede local só é permitido o botão "adiar" da notificação do celular (protegido por token).
        # A agenda em si continua acessível somente neste computador.
        if (-not $ctx.Request.IsLocal -and $caminho -ne '/api/celular/adiar') {
            Send-Erro $ctx 403 'Acesso permitido somente neste computador.'; return
        }
        if ($caminho.StartsWith('/api/')) { Invoke-Api $ctx } else { Send-Arquivo $ctx $caminho }
    }
    catch {
        Write-Warning "Erro em $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath): $($_.Exception.Message)"
        try { Send-Erro $ctx 500 ('Erro interno: ' + $_.Exception.Message) } catch { }
    }
}

# ---------------------------------------------------------------- inicialização
$cfgCelular = Get-ConfigCelular
$listener = $null
if ($cfgCelular.adiarPeloCelular) {
    # aceitar conexões da rede local exige a liberação feita uma única vez pelo "liberar-rede.bat" (como administrador)
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://+:$Porta/")
        $listener.Start()
        $script:RedeLiberada = $true
    }
    catch {
        Write-Warning 'Botões de adiar no celular desativados: a porta ainda não foi liberada para a rede.'
        Write-Warning 'Execute "liberar-rede.bat" como administrador (uma única vez) e reinicie o servidor.'
        try { $listener.Close() } catch { }
        $listener = $null
    }
}
if (-not $listener) {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Porta/")
    $listener.Start()
}
[void](Remove-Vencidos)
$url = "http://localhost:$Porta/"
Write-Host ''
Write-Host "  Agenda de Compromissos rodando em $url" -ForegroundColor Green
Write-Host "  Dados: $Arquivo"
if ($cfgCelular.ativo) { Write-Host "  Alertas no celular: ntfy, tópico $($cfgCelular.topico)$(if ($script:RedeLiberada) { ' (com botões de adiar)' })" }
Write-Host '  Pressione Ctrl+C para encerrar.'
Write-Host ''
if ($AbrirNavegador) { Start-Process $url }

$ultimaLimpeza = Get-Date
$ultimaVerificacao = [datetime]::MinValue

# rotinas periódicas, executadas mesmo sem nenhum navegador aberto
function Invoke-Rotinas {
    $agora = Get-Date
    if (($agora - $script:ultimaVerificacao).TotalSeconds -ge 5) {
        $script:ultimaVerificacao = $agora
        try { Invoke-VerificarAlarmes } catch { Write-Warning "Falha ao verificar alarmes: $($_.Exception.Message)" }
    }
    if (($agora - $script:ultimaLimpeza).TotalMinutes -ge 1) {
        $script:ultimaLimpeza = $agora
        try { [void](Remove-Vencidos) } catch { Write-Warning "Falha na limpeza: $($_.Exception.Message)" }
    }
    # calendários externos: incorpora resultados novos e sincroniza a cada 5 minutos
    try { Update-Externos } catch { Write-Warning "Falha ao incorporar calendários externos: $($_.Exception.Message)" }
    if (($agora - $script:ultimaSinc).TotalMinutes -ge $IntervaloSincMin) {
        try { [void](Start-Sincronizacao) } catch { Write-Warning "Falha ao iniciar sincronização: $($_.Exception.Message)" }
    }
}

try {
    while ($listener.IsListening) {
        Invoke-Rotinas
        $async = $listener.BeginGetContext($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(500)) { Invoke-Rotinas }
        Invoke-Requisicao ($listener.EndGetContext($async))
    }
}
finally {
    $listener.Stop(); $listener.Close()
    Write-Host 'Servidor encerrado.'
}
