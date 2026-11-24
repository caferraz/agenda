<#
  Janela de alarme da Agenda de Compromissos.
  Aberta pelo servidor (servidor.ps1) no horário do aviso: fica SEMPRE NA FRENTE de todas as
  outras janelas, pisca e toca som até o usuário clicar em "OK, ciente" ou adiar.
  Não precisa ser executada manualmente.
#>
param(
    [Parameter(Mandatory = $true)][string]$Dados,   # JSON do compromisso em Base64 (UTF-8)
    [int]$Porta = 8085
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$c      = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Dados)) | ConvertFrom-Json
$Inv    = [Globalization.CultureInfo]::InvariantCulture
$Pt     = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$Inicio = [datetime]::ParseExact("$($c.data) $($c.inicio)", 'yyyy-MM-dd HH:mm', $Inv)
$Teste  = [bool]$c.teste
$Api    = "http://localhost:$Porta/api/compromissos"
$OpcoesAdiar = @(5, 2, 1)
$SomMaxSegundos = 120

# ---------------------------------------------------------------- janela
$corForte = [Drawing.Color]::FromArgb(220, 38, 38)
$corEscura = [Drawing.Color]::FromArgb(127, 29, 29)
$fonte = 'Segoe UI'

$form = New-Object Windows.Forms.Form
$form.Text = 'Lembrete de compromisso - Agenda'
$form.ClientSize = New-Object Drawing.Size(480, 290)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true            # sobreposto a todas as outras janelas
$form.ShowInTaskbar = $true
$form.BackColor = [Drawing.Color]::White
$form.KeyPreview = $true

$faixa = New-Object Windows.Forms.Panel
$faixa.Dock = 'Top'
$faixa.Height = 56
$faixa.BackColor = $corForte
$form.Controls.Add($faixa)

$lblCab = New-Object Windows.Forms.Label
$lblCab.Text = [char]0x23F0 + '  LEMBRETE DE COMPROMISSO' + $(if ($Teste) { '  (TESTE)' } else { '' })
$lblCab.ForeColor = [Drawing.Color]::White
$lblCab.Font = New-Object Drawing.Font($fonte, 14, [Drawing.FontStyle]::Bold)
$lblCab.AutoSize = $false
$lblCab.Dock = 'Fill'
$lblCab.TextAlign = 'MiddleCenter'
$faixa.Controls.Add($lblCab)

function New-Rotulo([string]$texto, [int]$y, [float]$tam, [Drawing.FontStyle]$estilo, [Drawing.Color]$cor, [int]$alt) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $texto
    $l.Font = New-Object Drawing.Font($fonte, $tam, $estilo)
    $l.ForeColor = $cor
    $l.AutoSize = $false
    $l.Location = New-Object Drawing.Point(20, $y)
    $l.Size = New-Object Drawing.Size(440, $alt)
    $l.AutoEllipsis = $true
    $form.Controls.Add($l)
    return $l
}

$diaTxt = $Inicio.ToString('dddd, dd/MM/yyyy', $Pt)
$diaTxt = $diaTxt.Substring(0, 1).ToUpper() + $diaTxt.Substring(1)
[void](New-Rotulo $c.titulo 68 15 ([Drawing.FontStyle]::Bold) ([Drawing.Color]::FromArgb(15, 23, 42)) 34)
[void](New-Rotulo "$diaTxt  ·  $($c.inicio) às $($c.fim)" 104 11 ([Drawing.FontStyle]::Regular) ([Drawing.Color]::FromArgb(71, 85, 105)) 24)
$lblFalta = New-Rotulo '' 132 12 ([Drawing.FontStyle]::Bold) $corForte 26

$lblAdiar = New-Rotulo 'Adiar o alarme para:' 172 9.5 ([Drawing.FontStyle]::Regular) ([Drawing.Color]::FromArgb(71, 85, 105)) 20
$botoesAdiar = @()
$x = 20
foreach ($n in $OpcoesAdiar) {
    $b = New-Object Windows.Forms.Button
    $b.Text = "$n min antes"
    $b.Tag = $n
    $b.Location = New-Object Drawing.Point($x, 194)
    $b.Size = New-Object Drawing.Size(104, 32)
    $b.Font = New-Object Drawing.Font($fonte, 9.5)
    $b.Add_Click({ Invoke-Adiar ([int]$this.Tag) })
    $form.Controls.Add($b)
    $botoesAdiar += $b
    $x += 112
}

$btnAbrir = New-Object Windows.Forms.Button
$btnAbrir.Text = 'Abrir agenda'
$btnAbrir.Location = New-Object Drawing.Point(20, 242)
$btnAbrir.Size = New-Object Drawing.Size(120, 34)
$btnAbrir.Font = New-Object Drawing.Font($fonte, 9.5)
$btnAbrir.Add_Click({ Start-Process "http://localhost:$Porta/" })
$form.Controls.Add($btnAbrir)

# reunião online (Teams/Meet/Zoom importada do Outlook/Google): abre o link e encerra o alarme
$Link = [string]$c.link
if ($Link -match '^https://[^\s"''<>\\]+$') {
    $btnReuniao = New-Object Windows.Forms.Button
    $btnReuniao.Text = 'Entrar na reunião'
    $btnReuniao.Location = New-Object Drawing.Point(148, 242)
    $btnReuniao.Size = New-Object Drawing.Size(144, 34)
    $btnReuniao.Font = New-Object Drawing.Font($fonte, 9.5, [Drawing.FontStyle]::Bold)
    $btnReuniao.BackColor = [Drawing.Color]::FromArgb(91, 95, 199)
    $btnReuniao.ForeColor = [Drawing.Color]::White
    $btnReuniao.FlatStyle = 'Flat'
    $btnReuniao.Add_Click({ Start-Process $Link; $form.Close() })
    $form.Controls.Add($btnReuniao)
}

$btnOk = New-Object Windows.Forms.Button
$btnOk.Text = 'OK, ciente'
$btnOk.Location = New-Object Drawing.Point(300, 242)
$btnOk.Size = New-Object Drawing.Size(160, 34)
$btnOk.Font = New-Object Drawing.Font($fonte, 10.5, [Drawing.FontStyle]::Bold)
$btnOk.BackColor = $corForte
$btnOk.ForeColor = [Drawing.Color]::White
$btnOk.FlatStyle = 'Flat'
$btnOk.Add_Click({ $form.Close() })
$form.Controls.Add($btnOk)
$form.AcceptButton = $btnOk

# ---------------------------------------------------------------- som
$wav = Join-Path $env:windir 'Media\Alarm01.wav'
$player = $null
if (Test-Path $wav) {
    try { $player = New-Object System.Media.SoundPlayer $wav; $player.PlayLooping() } catch { $player = $null }
}
function Stop-Som { if ($script:player) { $script:player.Stop() }; $script:somAtivo = $false }
$script:somAtivo = $true

# ---------------------------------------------------------------- atualização a cada 0,5 s
$inicioAlarme = Get-Date
$pisca = $false
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $script:pisca = -not $script:pisca
    $faixa.BackColor = if ($script:pisca -and $script:somAtivo) { $corEscura } else { $corForte }

    $min = [Math]::Round(($Inicio - (Get-Date)).TotalMinutes)
    $lblFalta.Text = if ($min -gt 0) { "Começa em $min minuto(s)" } elseif ($min -eq 0) { 'Começa agora' } else { "Começou há $(-$min) minuto(s)" }

    $possivel = 0
    foreach ($b in $botoesAdiar) {
        $ok = (-not $Teste) -and ($Inicio.AddMinutes(-[int]$b.Tag) -gt (Get-Date))
        $b.Visible = $ok
        if ($ok) { $possivel++ }
    }
    $lblAdiar.Visible = $possivel -gt 0

    $seg = ((Get-Date) - $inicioAlarme).TotalSeconds
    if ($script:somAtivo) {
        if ($seg -ge $SomMaxSegundos) { Stop-Som }
        elseif (-not $player -and [int]($seg * 2) % 3 -eq 0) { [System.Media.SystemSounds]::Exclamation.Play() }
    }
    if (-not $form.TopMost) { $form.TopMost = $true }

    # a cada ~4 s: se o alarme foi adiado pelo celular/relógio (ou o compromisso sumiu), fecha esta janela
    $script:ticks++
    if (-not $Teste -and $script:ticks % 8 -eq 0) {
        try {
            $achou = $null
            foreach ($x in (Invoke-RestMethod -Uri $Api -TimeoutSec 2)) { if ($x.id -eq $c.id) { $achou = $x } }
            if (-not $achou -or $null -ne $achou.adiadoPara) { $form.Close() }
        } catch { }
    }
})
$script:ticks = 0

function Invoke-Adiar([int]$n) {
    try {
        $corpo = [Text.Encoding]::UTF8.GetBytes((@{ minutosAntes = $n } | ConvertTo-Json -Compress))
        Invoke-RestMethod -Method Post -Uri "$Api/$($c.id)/adiar" -ContentType 'application/json; charset=utf-8' -Body $corpo | Out-Null
        $form.Close()
    }
    catch {
        $msg = $_.Exception.Message
        try { if ($_.ErrorDetails.Message) { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).erro } } catch { }
        [void][Windows.Forms.MessageBox]::Show($form, "Não foi possível adiar: $msg", 'Agenda', 'OK', 'Warning')
    }
}

$form.Add_Shown({
    $form.TopMost = $true
    $form.Activate()
    $form.BringToFront()
    $timer.Start()
})
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
$form.Add_FormClosed({ $timer.Stop(); Stop-Som })

[void]$form.ShowDialog()
