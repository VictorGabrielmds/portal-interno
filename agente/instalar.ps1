<#
  Instala (ou atualiza) o agente SVT Monitor neste computador.

  Rode no PowerShell como Administrador. O comando pronto, com o token, fica na tela
  Infraestrutura do portal (botao "Instalar agente"). Exemplos:

    .\instalar.ps1 -Token SEU_TOKEN
    .\instalar.ps1 -Token SEU_TOKEN -Coletor                 (computador sempre ligado que varre a rede)
    .\instalar.ps1 -Token SEU_TOKEN -Coletor -Redes 192.168.0.0/24,192.168.1.0/24
    .\instalar.ps1 -Desinstalar

  O que faz:
    - desliga o agente antigo (tarefa "svt_telemetria"), se existir;
    - copia o svt-monitor.ps1 para C:\ProgramData\SVT-Monitor (baixa do portal se nao estiver ao lado);
    - grava o config.json (url, token, coletor, redes) so com acesso de SYSTEM e Administradores;
    - cria a tarefa agendada "SVT Monitor": como SYSTEM, ao ligar e a cada 5 minutos;
    - roda uma vez e mostra se o portal recebeu.
#>
[CmdletBinding()]
param(
  [string]$Token,
  [string]$Url = 'https://us-central1-portal-interno-svt.cloudfunctions.net/receberTelemetria',
  [switch]$Coletor,
  [string[]]$Redes = @(),
  [string]$Comunidade = 'public',
  [string]$Origem = 'https://portal.svtfaculdade.edu.br/agente',
  [switch]$Desinstalar
)

$ErrorActionPreference = 'Stop'
$PASTA = Join-Path $env:ProgramData 'SVT-Monitor'
$TAREFA = 'SVT Monitor'
$TAREFA_USO = 'SVT Monitor - Uso'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Abra o PowerShell como Administrador e rode de novo.' -ForegroundColor Red
  exit 1
}

if ($Desinstalar) {
  Unregister-ScheduledTask -TaskName $TAREFA -Confirm:$false -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TAREFA_USO -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $PASTA -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'SVT Monitor removido deste computador.' -ForegroundColor Green
  exit 0
}

if (-not $Token) {
  Write-Host 'Informe o token: .\instalar.ps1 -Token SEU_TOKEN (copie da tela Infraestrutura do portal).' -ForegroundColor Red
  exit 1
}

# Agente antigo (tarefa "svt_telemetria", que roda C:\SVT\agente_svt.ps1 sem parar): desliga, senao o
# computador continua gravando tambem pelo caminho velho. O arquivo em C:\SVT fica onde esta.
$antigas = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
  $_.TaskName -eq 'svt_telemetria' -or (@($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'agente_svt\.ps1')
})
foreach ($antiga in $antigas) {
  Stop-ScheduledTask -TaskName $antiga.TaskName -TaskPath $antiga.TaskPath -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $antiga.TaskName -TaskPath $antiga.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Agente antigo desligado (tarefa $($antiga.TaskName))." -ForegroundColor Cyan
}

# Atualizacao: para a rodada em andamento (ainda com o script velho). Sem isso o Windows ignora o
# Start-ScheduledTask la embaixo enquanto ela roda, e a primeira rodada depois de instalar e a antiga.
Stop-ScheduledTask -TaskName $TAREFA -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $TAREFA_USO -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force -Path $PASTA | Out-Null
$destino = Join-Path $PASTA 'svt-monitor.ps1'
$aoLado = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'svt-monitor.ps1' } else { '' }
if ($aoLado -and (Test-Path $aoLado)) {
  Copy-Item $aoLado $destino -Force
} else {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "$Origem/svt-monitor.ps1" -OutFile $destino -UseBasicParsing
}
Unblock-File $destino -ErrorAction SilentlyContinue

# Atualizacao: encerra o processo do vigia que ja estava rodando (codigo ANTIGO na memoria da sessao do
# usuario), que o Stop-ScheduledTask acima pode nao derrubar se ficou orfao. Assim a versao nova vale
# sem deslogar, e nao ficam dois vigias ao mesmo tempo. Como administrador, alcanca as sessoes.
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'svt-uso\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

# Vigia do uso de sites (roda na sessao de cada usuario). Fica dormindo ate o portal ligar a vigilancia.
$destinoUso = Join-Path $PASTA 'svt-uso.ps1'
$aoLadoUso = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'svt-uso.ps1' } else { '' }
if ($aoLadoUso -and (Test-Path $aoLadoUso)) {
  Copy-Item $aoLadoUso $destinoUso -Force
} else {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "$Origem/svt-uso.ps1" -OutFile $destinoUso -UseBasicParsing
}
Unblock-File $destinoUso -ErrorAction SilentlyContinue

# Pasta onde o vigia grava o uso do dia. "Caixa de deposito": cada usuario CRIA e atualiza so o SEU
# arquivo e NAO le/lista o dos outros; o sistema (agente) e os administradores leem todos. Assim um
# funcionario nao ve o uso de outro no mesmo computador.
$pastaUso = Join-Path $PASTA 'uso'
New-Item -ItemType Directory -Force -Path $pastaUso | Out-Null
try {
  $aclUso = New-Object System.Security.AccessControl.DirectorySecurity
  $aclUso.SetAccessRuleProtection($true, $false)   # nao herda: so as regras abaixo valem
  $sistema = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')      # SISTEMA
  $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')   # Administradores
  $dono = New-Object System.Security.Principal.SecurityIdentifier('S-1-3-0')          # Dono do arquivo (quem criou)
  $usuarios = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545') # Usuarios
  $tudo = 'ContainerInherit,ObjectInherit'
  $aclUso.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sistema, 'FullControl', $tudo, 'None', 'Allow')))
  $aclUso.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', $tudo, 'None', 'Allow')))
  # Dono pode reescrever o proprio arquivo (vale so para os arquivos criados, nao para a pasta).
  $aclUso.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($dono, 'Modify', 'ObjectInherit', 'InheritOnly', 'Allow')))
  # Usuarios: so criar arquivo nesta pasta (sem listar nem abrir os dos outros).
  $aclUso.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usuarios, 'CreateFiles,AppendData,ReadAttributes,Synchronize', 'None', 'None', 'Allow')))
  Set-Acl -Path $pastaUso -AclObject $aclUso
} catch { Write-Host "Aviso: nao consegui restringir a pasta de uso ($($_.Exception.Message))." -ForegroundColor Yellow }

# "-Redes a,b" chega como um texto so quando vem de outro processo.
$listaRedes = @($Redes | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ })
$config = [ordered]@{ url = $Url; token = $Token; coletor = [bool]$Coletor; redes = $listaRedes; snmpComunidade = $Comunidade }
$arquivoConfig = Join-Path $PASTA 'config.json'
[System.IO.File]::WriteAllText($arquivoConfig, ($config | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

# O token fica legivel so para o sistema e para administradores.
try {
  $acl = New-Object System.Security.AccessControl.FileSecurity
  $acl.SetAccessRuleProtection($true, $false)
  # Pelo SID, e nao pelo nome: no Windows em portugues as contas se chamam "SISTEMA" e "Administradores".
  foreach ($conta in @('S-1-5-18', 'S-1-5-32-544')) {
    $sid = New-Object System.Security.Principal.SecurityIdentifier($conta)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
  }
  Set-Acl -Path $arquivoConfig -AclObject $acl
} catch { Write-Host "Aviso: nao consegui restringir o acesso ao config.json ($($_.Exception.Message))." -ForegroundColor Yellow }

$acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destino`""
$aCada5 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$aoLigar = New-ScheduledTaskTrigger -AtStartup
$conta = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$ajustes = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TAREFA -Action $acao -Trigger @($aCada5, $aoLigar) -Principal $conta -Settings $ajustes -Description 'Envia ao Portal Interno SVT o estado deste computador (e da rede, se for o coletor).' -Force | Out-Null

# Tarefa do vigia de uso: roda na sessao de QUALQUER usuario que logar, com a conta dele (nao sistema),
# porque so a sessao do usuario enxerga a janela que esta na frente. Fica dormindo ate o portal ligar.
$acaoUso = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destinoUso`""
$aoLogar = New-ScheduledTaskTrigger -AtLogOn
$contaUso = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
$ajustesUso = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$ajustesUso.ExecutionTimeLimit = 'PT0S'
Register-ScheduledTask -TaskName $TAREFA_USO -Action $acaoUso -Trigger $aoLogar -Principal $contaUso -Settings $ajustesUso -Description 'Mede tempo em sites e programas configurados, na sessao do usuario e com aceite. Nao grava conteudo, mensagens, senhas, URLs ou titulos.' -Force | Out-Null
Start-ScheduledTask -TaskName $TAREFA_USO -ErrorAction SilentlyContinue

Write-Host "Agente instalado em $PASTA. Enviando o primeiro relatorio..." -ForegroundColor Cyan
Start-ScheduledTask -TaskName $TAREFA
$limite = (Get-Date).AddMinutes(3)
do { Start-Sleep -Seconds 3 } while ((Get-ScheduledTask -TaskName $TAREFA).State -eq 'Running' -and (Get-Date) -lt $limite)

$log = Join-Path $PASTA 'svt-monitor.log'
$ultimas = if (Test-Path $log) { Get-Content $log -Tail 4 } else { @() }
if ($ultimas -match 'Enviado') {
  Write-Host 'Pronto: o portal recebeu os dados deste computador.' -ForegroundColor Green
} else {
  Write-Host 'O portal ainda nao confirmou. Ultimas linhas do registro:' -ForegroundColor Yellow
}
$ultimas | ForEach-Object { Write-Host "  $_" }
if ($Coletor) { Write-Host 'Este computador tambem varre a rede (coletor). Deixe-o sempre ligado.' -ForegroundColor Cyan }
