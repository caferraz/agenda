<#
  Agenda de Compromissos - execução em segundo plano (ícone na bandeja, ao lado do relógio).
  Normalmente iniciado pelo Agenda.exe. Mantém o servidor (servidor.ps1) rodando de forma oculta
  e o reinicia sozinho se ele parar. Menu do ícone: abrir agenda, testar alarme, iniciar com o
  Windows, reiniciar servidor, ver registro e sair.
#>
param([int]$Porta = 8085)

$ErrorActionPreference = 'Stop'
$Raiz        = Split-Path -Parent $MyInvocation.MyCommand.Path
$PastaDados  = Join-Path $Raiz 'dados'
$Servidor    = Join-Path $Raiz 'servidor.ps1'
$Log         = Join-Path $PastaDados 'servidor.log'
$ArqBandeja  = Join-Path $PastaDados 'bandeja.json'
$Exe         = Join-Path $Raiz 'Agenda.exe'
# nome próprio, para não colidir com o atalho que o Chrome cria ao instalar a agenda como app
$Atalho      = Join-Path ([Environment]::GetFolderPath('Startup')) 'Agenda de Compromissos - alarmes.lnk'
$Url         = "http://localhost:$Porta/"
$Titulo      = 'Agenda de Compromissos'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
if (-not (Test-Path $PastaDados)) { New-Item -ItemType Directory -Path $PastaDados | Out-Null }

# ---------------------------------------------------------------- instância única
# Se já estiver rodando, apenas abre a agenda no navegador e sai.
$criado = $false
$mutex = New-Object Threading.Mutex($true, "Local\AgendaCompromissos-Bandeja-$Porta", [ref]$criado)
if (-not $criado) { Start-Process $Url; return }

# ---------------------------------------------------------------- servidor
$script:proc = $null
$script:ultimoInicio = [datetime]::MinValue
$script:reinicios = 0
$script:saindo = $false

function Test-Servidor {
    try {
        $r = [Net.WebRequest]::Create("$($Url)api/celular")
        $r.Timeout = 3000
        $resp = $r.GetResponse(); $ok = ([int]$resp.StatusCode -eq 200); $resp.Close()
        return $ok
    } catch { return $false }
}

function Start-Servidor {
    # registro simples: reinicia o arquivo de log quando passar de 1 MB
    if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) { Remove-Item $Log -Force }
    $cmd = "& '{0}' -Porta {1} *>> '{2}'" -f $Servidor.Replace("'", "''"), $Porta, $Log.Replace("'", "''")
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Raiz
    $script:proc = [Diagnostics.Process]::Start($psi)
    $script:ultimoInicio = Get-Date
}

function Stop-Servidor {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { $script:proc.Kill(); $script:proc.WaitForExit(3000) | Out-Null } catch { }
    }
    $script:proc = $null
}

# ---------------------------------------------------------------- iniciar com o Windows
function Test-AutoInicio { Test-Path $Atalho }
function Set-AutoInicio([bool]$ligar) {
    if ($ligar) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($Atalho)
        if (Test-Path $Exe) {
            $lnk.TargetPath = $Exe
            $lnk.IconLocation = "$Exe,0"
        } else {
            $lnk.TargetPath = 'powershell.exe'
            $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
        }
        $lnk.WorkingDirectory = $Raiz
        $lnk.Description = 'Agenda de Compromissos - alarmes em segundo plano'
        $lnk.Save()
    }
    elseif (Test-Path $Atalho) { Remove-Item $Atalho -Force }
}

# ---------------------------------------------------------------- ícone (desenhado na hora)
function New-IconeAgenda {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $azul = [Drawing.Color]::FromArgb(37, 99, 235)
    $escuro = [Drawing.Color]::FromArgb(30, 64, 175)
    $g.FillRectangle((New-Object Drawing.SolidBrush $azul), 1, 4, 30, 27)
    $g.FillRectangle((New-Object Drawing.SolidBrush $escuro), 1, 4, 30, 8)
    $g.FillRectangle([Drawing.Brushes]::White, 4, 14, 24, 14)
    $g.FillRectangle([Drawing.Brushes]::White, 8, 1, 4, 8)
    $g.FillRectangle([Drawing.Brushes]::White, 20, 1, 4, 8)
    $caneta = New-Object Drawing.Pen($azul, 2.5)
    $g.DrawEllipse($caneta, 10, 15, 12, 12)
    $g.DrawLine($caneta, 16, 18, 16, 21)
    $g.DrawLine($caneta, 16, 21, 19, 23)
    $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ---------------------------------------------------------------- bandeja
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-IconeAgenda
$tray.Text = "$Titulo - alarmes ativos"
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
function Add-Item([string]$texto, [scriptblock]$acao) {
    $i = New-Object Windows.Forms.ToolStripMenuItem $texto
    $i.Add_Click($acao)
    [void]$menu.Items.Add($i)
    return $i
}

$miAbrir = Add-Item 'Abrir agenda' { Start-Process $Url }
$miAbrir.Font = New-Object Drawing.Font($miAbrir.Font, [Drawing.FontStyle]::Bold)
[void](Add-Item 'Testar alarme' {
    try {
        $r = [Net.WebRequest]::Create("$($Url)api/testar-alarme"); $r.Method = 'POST'; $r.ContentLength = 0
        $r.GetResponse().Close()
    } catch { $tray.ShowBalloonTip(4000, $Titulo, 'O servidor não respondeu. Tente "Reiniciar servidor".', 'Warning') }
})
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miAuto = Add-Item 'Iniciar com o Windows' {
    Set-AutoInicio (-not (Test-AutoInicio))
    $miAuto.Checked = Test-AutoInicio
}
$miAuto.Checked = Test-AutoInicio
[void](Add-Item 'Reiniciar servidor' {
    Stop-Servidor
    Start-Sleep -Milliseconds 500
    if (-not (Test-Servidor)) { Start-Servidor }
    $tray.ShowBalloonTip(3000, $Titulo, 'Servidor reiniciado.', 'Info')
})
[void](Add-Item 'Ver registro (log)' { if (Test-Path $Log) { Start-Process notepad.exe $Log } })
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void](Add-Item 'Sair (desliga os alarmes)' {
    $r = [Windows.Forms.MessageBox]::Show(
        "Ao sair, os alarmes deixam de funcionar até a agenda ser aberta novamente.`n`nDeseja sair mesmo assim?",
        $Titulo, 'YesNo', 'Warning', 'Button2')
    if ($r -eq 'Yes') {
        $script:saindo = $true
        $vigia.Stop()
        Stop-Servidor
        $tray.Visible = $false
        $tray.Dispose()
        [Windows.Forms.Application]::ExitThread()
    }
})
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Start-Process $Url } })

# ---------------------------------------------------------------- vigia: mantém o servidor sempre no ar
$vigia = New-Object Windows.Forms.Timer
$vigia.Interval = 5000
$vigia.Add_Tick({
    if ($script:saindo) { return }
    $vivo = $script:proc -and -not $script:proc.HasExited
    if ($vivo) { return }
    if (Test-Servidor) { return }                                   # já há um servidor atendendo (ex.: iniciar.bat antigo)
    if (((Get-Date) - $script:ultimoInicio).TotalSeconds -lt 15) { return }   # evita reinícios em sequência
    Start-Servidor
    $script:reinicios++
    $tray.ShowBalloonTip(4000, $Titulo, 'O servidor da agenda parou e foi reiniciado automaticamente.', 'Info')
})

# ---------------------------------------------------------------- início
$primeiraVez = -not (Test-Path $ArqBandeja)
if ($primeiraVez) {
    Set-AutoInicio $true            # o pedido é ficar sempre ligado: já inicia com o Windows
    $miAuto.Checked = Test-AutoInicio
    [IO.File]::WriteAllText($ArqBandeja, '{ "configurado": true }')
}
if (-not (Test-Servidor)) { Start-Servidor }
$vigia.Start()

$msg = 'Rodando em segundo plano. Os alarmes funcionam enquanto este ícone estiver aqui.'
if ($primeiraVez) { $msg += ' Configurado para iniciar junto com o Windows.' }
$tray.ShowBalloonTip(5000, $Titulo, $msg, 'Info')

[Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
