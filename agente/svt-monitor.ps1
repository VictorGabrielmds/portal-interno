<#
  SVT Monitor - agente de monitoramento do Portal Interno SVT (modulo Infraestrutura)

  Cada computador manda, a cada 5 minutos (tarefa agendada criada pelo instalar.ps1):
    hardware, uso de CPU/RAM/disco, rede (cabo ou Wi-Fi, sinal, velocidade), latencia ate o
    roteador e a internet, impressoras instaladas e antivirus.
  Diagnostico (desde a 2.5.0): rajada de desempenho (CPU, disco, memoria), NOMES dos programas que
    mais pesam e eventos do Windows (programa que travou ou fechou, desligamento inesperado, erro de
    disco). Nunca titulo de janela, caminho, linha de comando, usuario ou conteudo. Desliga com
    "diagnostico": false no config.json.
  O computador "coletor" (um que fica sempre ligado) tambem varre a rede: quem responde,
  MAC, nome, portas abertas, impressoras por SNMP (status, toner, contador) e a internet.

  Uso:
    svt-monitor.ps1                                   le config.json ao lado e envia
    svt-monitor.ps1 -Teste                            so mostra o JSON (nao envia nada)
    svt-monitor.ps1 -Teste -Coletor -Redes 192.168.0.1/32   testa a varredura num endereco so

  Arquivo sem acentos de proposito: o Windows PowerShell 5.1 le .ps1 sem BOM como ANSI.
#>
[CmdletBinding()]
param(
  [switch]$Teste,
  [switch]$Coletor,
  [string[]]$Redes,
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$VERSAO = '2.5.0'
# $PSScriptRoot fica vazio nos valores padrao do param() do PowerShell 5.1.
$PASTA = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Config) { $Config = Join-Path $PASTA 'config.json' }
$LOG = Join-Path $PASTA 'svt-monitor.log'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Escrever-Log([string]$Mensagem) {
  try {
    if ((Test-Path $LOG) -and (Get-Item $LOG).Length -gt 1MB) { Move-Item $LOG "$LOG.1" -Force }
    Add-Content -Path $LOG -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Mensagem) -Encoding UTF8
  } catch {}
  if ($Teste) { Write-Host $Mensagem }
}

function Iso($Data) { if ($Data) { try { return ([datetime]$Data).ToUniversalTime().ToString('o') } catch {} }; return '' }
function Arredondar($Valor, [int]$Casas = 1) { if ($null -eq $Valor) { return $null }; return [math]::Round([double]$Valor, $Casas) }

# ---------------------------------------------------------------- configuracao

function Ler-Config {
  $cfg = [ordered]@{ url = ''; token = ''; coletor = $false; redes = @(); snmpComunidade = 'public'; coletarUso = $true; diagnostico = $true }
  if (Test-Path $Config) {
    try {
      $lido = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($campo in @('url', 'token', 'coletor', 'redes', 'snmpComunidade', 'coletarUso', 'diagnostico')) {
        if ($null -ne $lido.$campo) { $cfg[$campo] = $lido.$campo }
      }
    } catch { Escrever-Log "config.json invalido: $($_.Exception.Message)" }
  }
  if ($Coletor) { $cfg.coletor = $true }
  if ($Redes) { $cfg.redes = @($Redes) }
  return $cfg
}

# ---------------------------------------------------------------- rede: utilitarios

function Medir-Pings([string[]]$Ips, [int]$TimeoutMs = 800) {
  # Ping em paralelo; devolve @{ ip = milissegundos } so de quem respondeu.
  $resultado = @{}
  $Ips = @($Ips)
  if (-not $Ips.Count) { return $resultado }
  # Lotes por indice: devolver os lotes de uma funcao faz o PowerShell desmontar o lote unico
  # (ate 256 enderecos) em itens soltos, e o ping vira um por vez.
  for ($i = 0; $i -lt $Ips.Count; $i += 256) {
    $lote = @($Ips[$i..([math]::Min($i + 256, $Ips.Count) - 1)])
    $pendentes = @()
    foreach ($ip in $lote) {
      $ping = New-Object System.Net.NetworkInformation.Ping
      $pendentes += [pscustomobject]@{ Ip = $ip; Ping = $ping; Tarefa = $ping.SendPingAsync($ip, $TimeoutMs) }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($pendentes | ForEach-Object { $_.Tarefa }), $TimeoutMs + 3000) } catch {}
    foreach ($p in $pendentes) {
      try {
        if ($p.Tarefa.Status -eq 'RanToCompletion' -and $p.Tarefa.Result.Status -eq 'Success') { $resultado[$p.Ip] = [int]$p.Tarefa.Result.RoundtripTime }
      } catch {}
      $p.Ping.Dispose()
    }
  }
  return $resultado
}

function Medir-Latencia([string]$Destino, [int]$Vezes = 4) {
  # Media em ms e perda em %, com pings em sequencia.
  $tempos = @()
  $perdidos = 0
  $ping = New-Object System.Net.NetworkInformation.Ping
  for ($i = 0; $i -lt $Vezes; $i++) {
    try {
      $r = $ping.Send($Destino, 1000)
      if ($r.Status -eq 'Success') { $tempos += [int]$r.RoundtripTime } else { $perdidos++ }
    } catch { $perdidos++ }
  }
  $ping.Dispose()
  $media = $null
  if ($tempos.Count) { $media = [int][math]::Round(($tempos | Measure-Object -Average).Average) }
  return [pscustomobject]@{ latenciaMs = $media; perda = [int][math]::Round(100 * $perdidos / $Vezes) }
}

function Testar-Dns {
  try { return [bool]([System.Net.Dns]::GetHostAddresses('www.google.com').Count) } catch { return $false }
}

function Testar-Portas([string[]]$Ips, [int[]]$Portas, [int]$TimeoutMs = 800) {
  # Conexao TCP em paralelo; devolve @{ ip = @(portas abertas) }.
  $abertas = @{}
  $pares = @(foreach ($ip in $Ips) { foreach ($porta in $Portas) { [pscustomobject]@{ Ip = $ip; Porta = $porta } } })
  for ($i = 0; $i -lt $pares.Count; $i += 400) {
    $lote = @($pares[$i..([math]::Min($i + 400, $pares.Count) - 1)])
    $tentativas = @()
    foreach ($par in $lote) {
      if (-not $par) { continue }
      $cliente = New-Object System.Net.Sockets.TcpClient
      $tentativas += [pscustomobject]@{ Ip = $par.Ip; Porta = $par.Porta; Cliente = $cliente; Tarefa = $cliente.ConnectAsync($par.Ip, $par.Porta) }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tentativas | ForEach-Object { $_.Tarefa }), $TimeoutMs) } catch {}
    foreach ($t in $tentativas) {
      try {
        if ($t.Tarefa.Status -eq 'RanToCompletion' -and $t.Cliente.Connected) {
          if (-not $abertas.ContainsKey($t.Ip)) { $abertas[$t.Ip] = New-Object System.Collections.ArrayList }
          [void]$abertas[$t.Ip].Add($t.Porta)
        }
      } catch {}
      try { $t.Cliente.Close() } catch {}
    }
  }
  return $abertas
}

function Resolver-Nomes([string[]]$Ips, [int]$TimeoutMs = 2500) {
  $nomes = @{}
  $pendentes = @()
  foreach ($ip in $Ips) {
    try { $pendentes += [pscustomobject]@{ Ip = $ip; Tarefa = [System.Net.Dns]::GetHostEntryAsync($ip) } } catch {}
  }
  if (-not $pendentes) { return $nomes }
  try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($pendentes | ForEach-Object { $_.Tarefa }), $TimeoutMs) } catch {}
  foreach ($p in $pendentes) {
    try {
      if ($p.Tarefa.Status -eq 'RanToCompletion' -and $p.Tarefa.Result.HostName -and $p.Tarefa.Result.HostName -ne $p.Ip) { $nomes[$p.Ip] = $p.Tarefa.Result.HostName }
    } catch {}
  }
  return $nomes
}

function Ip-ParaNumero([string]$Ip) {
  $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
  return ([int64]$b[0] * 16777216) + ([int64]$b[1] * 65536) + ([int64]$b[2] * 256) + [int64]$b[3]
}
function Numero-ParaIp([int64]$N) {
  return '{0}.{1}.{2}.{3}' -f [int64][math]::Floor($N / 16777216), ([int64][math]::Floor($N / 65536) % 256), ([int64][math]::Floor($N / 256) % 256), ($N % 256)
}
function Rede-DoIp([string]$Ip, [int]$Prefixo) {
  $mascara = [int64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefixo))
  $base = [int64](Ip-ParaNumero $Ip) -band $mascara
  return '{0}/{1}' -f (Numero-ParaIp $base), $Prefixo
}
function Ips-DaRede([string]$Cidr, [int]$Maximo = 1024) {
  $partes = $Cidr.Split('/')
  $prefixo = [int]$partes[1]
  $base = Ip-ParaNumero $partes[0]
  $total = [math]::Pow(2, 32 - $prefixo)
  if ($prefixo -ge 31) { $inicio = 0; $fim = $total - 1 } else { $inicio = 1; $fim = $total - 2 }
  $fim = [math]::Min($fim, $inicio + $Maximo - 1)
  for ($i = $inicio; $i -le $fim; $i++) { Numero-ParaIp ([int64]($base + $i)) }
}
function Ip-NaRede([string]$Ip, [string]$Cidr) {
  $partes = $Cidr.Split('/')
  return (Rede-DoIp $Ip ([int]$partes[1])) -eq (Rede-DoIp $partes[0] ([int]$partes[1]))
}

function Formatar-Mac([string]$Mac) {
  $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
  if ($hex.Length -ne 12) { return '' }
  return ($hex -split '(..)' | Where-Object { $_ }) -join ':'
}

# ---------------------------------------------------------------- relatorio do computador

function Ler-Wifi {
  $saida = @()
  try { $saida = @(netsh wlan show interfaces 2>$null) } catch { return $null }
  $valor = {
    param([string]$Padrao)
    foreach ($linha in $saida) {
      # O valor vai num grupo com nome: o rotulo pode ter grupos proprios, como "(Sinal|Signal)".
      if ($linha -match "^\s*(?:$Padrao)\s*:\s*(?<valor>.+?)\s*$") { return $Matches['valor'] }
    }
    return ''
  }
  $ssid = & $valor 'SSID'
  if (-not $ssid) { return $null }
  $sinal = & $valor '(Sinal|Signal)'
  $rx = & $valor '(Taxa de recep[^:]*|Receive rate[^:]*)'
  $tx = & $valor '(Taxa de transmiss[^:]*|Transmit rate[^:]*)'
  return [ordered]@{
    ssid   = $ssid
    bssid  = (& $valor '(AP BSSID|BSSID)')
    sinal  = if ($sinal -match '(\d+)') { [int]$Matches[1] } else { $null }
    canal  = if ((& $valor '(Canal|Channel)') -match '(\d+)') { [int]$Matches[1] } else { $null }
    banda  = (& $valor '(Banda|Band)')
    radio  = (& $valor '(Tipo de r.{1,3}dio|Radio type)')
    rxMbps = if ($rx -match '([\d.,]+)') { [double]($Matches[1] -replace ',', '.') } else { $null }
    txMbps = if ($tx -match '([\d.,]+)') { [double]($Matches[1] -replace ',', '.') } else { $null }
  }
}

# Pede ao Windows uma busca nova de redes Wi-Fi (a lista guardada pode estar velha ou incompleta).
# Usa a API do Windows (wlanapi.dll); se nao der, fica a lista guardada.
$WLAN_CS = @'
using System;
using System.Runtime.InteropServices;
public static class SvtWlan {
  [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint versao, IntPtr r, out uint negociada, out IntPtr h);
  [DllImport("wlanapi.dll")] static extern int WlanEnumInterfaces(IntPtr h, IntPtr r, out IntPtr lista);
  [DllImport("wlanapi.dll")] static extern int WlanScan(IntPtr h, ref Guid g, IntPtr ssid, IntPtr ie, IntPtr r);
  [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
  [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
  public static int Buscar() {
    uint negociada; IntPtr h;
    if (WlanOpenHandle(2, IntPtr.Zero, out negociada, out h) != 0) return 0;
    int pedidos = 0;
    try {
      IntPtr lista;
      if (WlanEnumInterfaces(h, IntPtr.Zero, out lista) != 0) return 0;
      try {
        int total = Marshal.ReadInt32(lista);
        for (int i = 0; i < total; i++) {
          // WLAN_INTERFACE_INFO: GUID (16) + descricao WCHAR[256] (512) + estado (4) = 532 bytes, depois de 8 bytes de cabecalho
          Guid g = (Guid)Marshal.PtrToStructure(new IntPtr(lista.ToInt64() + 8 + i * 532), typeof(Guid));
          if (WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) pedidos++;
        }
      } finally { WlanFreeMemory(lista); }
    } finally { WlanCloseHandle(h, IntPtr.Zero); }
    return pedidos;
  }
}
'@

function Buscar-RedesWifi {
  try {
    if (-not ('SvtWlan' -as [type])) { Add-Type -TypeDefinition $WLAN_CS -ErrorAction Stop }
    if ([SvtWlan]::Buscar() -gt 0) { Start-Sleep -Seconds 4 }
  } catch { Escrever-Log "Busca de redes Wi-Fi nao disponivel: $($_.Exception.Message)" }
}

function Ler-RedesWifi {
  # Todos os APs que este computador enxerga (das redes da SVT e dos vizinhos): canal, sinal e, quando o
  # AP informa, quantos aparelhos estao conectados e quanto do canal esta ocupado.
  $saida = @()
  try { $saida = @(netsh wlan show networks mode=bssid 2>$null) } catch { return @() }
  $redes = New-Object System.Collections.ArrayList
  $ssid = ''
  $atual = $null
  foreach ($linha in $saida) {
    if ($linha -match '^SSID \d+\s*:\s?(?<v>.*)$') { $ssid = $Matches['v'].Trim(); $atual = $null; continue }
    if ($linha -match '^\s+BSSID \d+\s*:\s*(?<v>\S+)') {
      if ($redes.Count -ge 80) { break }
      $atual = [ordered]@{ ssid = $ssid; bssid = $Matches['v']; sinal = $null; canal = $null; banda = ''; radio = ''; estacoes = $null; usoCanal = $null }
      [void]$redes.Add($atual)
      continue
    }
    if (-not $atual) { continue }
    if ($linha -match '^\s*(?:Sinal|Signal)\s*:\s*(?<v>\d+)') { $atual.sinal = [int]$Matches['v'] }
    elseif ($linha -match '^\s*(?:Canal|Channel)\s*:\s*(?<v>\d+)') { $atual.canal = [int]$Matches['v'] }
    elseif ($linha -match '^\s*(?:Banda|Band)\s*:\s*(?<v>.+?)\s*$') { $atual.banda = $Matches['v'] }
    elseif ($linha -match '^\s*(?:Tipo de r.{1,3}dio|Radio type)\s*:\s*(?<v>.+?)\s*$') { $atual.radio = $Matches['v'] }
    elseif ($linha -match '(?:Esta.{1,4}es Conectadas|Connected Stations)\s*:\s*(?<v>\d+)') { $atual.estacoes = [int]$Matches['v'] }
    elseif ($linha -match '(?:Utiliza.{1,4}o do canal|Channel Utilization)\s*:\s*\d+\s*\((?<v>\d+)\s*%\)') { $atual.usoCanal = [int]$Matches['v'] }
  }
  return $redes
}

function Ler-Adaptadores {
  $lista = @()
  $adaptadores = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
  foreach ($a in $adaptadores) {
    $tipo = 'outro'
    if ($a.NdisPhysicalMedium -eq 9 -or $a.PhysicalMediaType -match '802\.11' -or $a.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') { $tipo = 'wifi' }
    elseif ($a.NdisPhysicalMedium -eq 14 -or $a.PhysicalMediaType -match '802\.3' -or $a.InterfaceDescription -match 'Ethernet|GbE|Gigabit|Realtek PCI') { $tipo = 'cabo' }
    $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' })
    $gateway = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $velocidade = $null
    try { if ($a.ReceiveLinkSpeed) { $velocidade = [int][math]::Round($a.ReceiveLinkSpeed / 1000000) } } catch {}
    $lista += [ordered]@{
      nome           = $a.Name
      descricao      = $a.InterfaceDescription
      tipo           = $tipo
      mac            = $a.MacAddress
      ipv4           = @($ips | ForEach-Object { $_.IPAddress })
      prefixo        = if ($ips) { [int]$ips[0].PrefixLength } else { $null }
      gateway        = if ($gateway -and $gateway -ne '0.0.0.0') { $gateway } else { '' }
      dns            = @($dns)
      velocidadeMbps = $velocidade
      dhcp           = [bool]($ips | Where-Object { $_.PrefixOrigin -eq 'Dhcp' })
    }
  }
  return $lista
}

function Ler-Impressoras {
  $lista = @()
  $portas = @{}
  try { Get-PrinterPort -ErrorAction Stop | ForEach-Object { $portas[$_.Name] = $_.PrinterHostAddress } } catch {}
  $impressoras = @()
  try { $impressoras = @(Get-Printer -ErrorAction Stop) } catch { return @() }
  foreach ($i in $impressoras) {
    if ($i.Name -match 'PDF|XPS|OneNote|Fax|Send To|Enviar para' -or $i.PortName -match '^(PORTPROMPT|nul|SHRFAX|FILE|Microsoft)') { continue }
    $ip = ''
    $conexao = 'outra'
    if ($i.Type -eq 'Connection') { $conexao = 'compartilhada' }
    elseif ($portas[$i.PortName]) { $conexao = 'rede'; $ip = [string]$portas[$i.PortName] }
    elseif ($i.PortName -match '^(USB|DOT4|LPT|WSD)') { if ($i.PortName -match '^WSD') { $conexao = 'rede' } else { $conexao = 'usb' } }
    if (-not $ip -and $i.PortName -match '(\d{1,3}(\.\d{1,3}){3})') { $ip = $Matches[1]; $conexao = 'rede' }
    $lista += [ordered]@{
      nome          = $i.Name
      driver        = $i.DriverName
      porta         = $i.PortName
      ip            = $ip
      conexao       = $conexao
      compartilhada = [bool]$i.Shared
      status        = [string]$i.PrinterStatus
    }
  }
  return $lista
}

function Ler-Antivirus {
  $lista = @()
  try {
    foreach ($av in @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop)) {
      $hex = '{0:x6}' -f [int]$av.productState
      $lista += [ordered]@{
        nome       = $av.displayName
        ativo      = @('10', '11') -contains $hex.Substring(2, 2)
        atualizado = $hex.Substring(4, 2) -eq '00'
      }
    }
  } catch {}
  return $lista
}

function Montar-RelatorioPc($Cfg = $null) {
  # Wi-Fi: so em computador com placa de Wi-Fi ligada.
  $wifi = Ler-Wifi
  $visiveis = @()
  if (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' -and ($_.NdisPhysicalMedium -eq 9 -or $_.PhysicalMediaType -match '802\.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') }) {
    Buscar-RedesWifi
    $visiveis = @(Ler-RedesWifi)
    if ($wifi) {
      $wifi = Ler-Wifi
      $doAp = $visiveis | Where-Object { $_.bssid -eq $wifi.bssid } | Select-Object -First 1
      if ($doAp) { $wifi.estacoes = $doAp.estacoes; $wifi.usoCanal = $doAp.usoCanal }
    }
  }
  $so = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $cpu = @(Get-CimInstance Win32_Processor)
  $bios = $null; try { $bios = Get-CimInstance Win32_BIOS } catch {}
  $placa = $null; try { $placa = Get-CimInstance Win32_BaseBoard } catch {}
  $gpus = @(); try { $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) } catch {}
  $discos = @(); try {
    $discos = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [ordered]@{ unidade = $_.DeviceID; rotulo = $_.VolumeName; totalGB = Arredondar ($_.Size / 1GB); livreGB = Arredondar ($_.FreeSpace / 1GB) }
      })
  } catch {}
  $fisicos = @(); try {
    $fisicos = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        [ordered]@{ modelo = $_.FriendlyName; tipo = if ($_.MediaType -eq 'SSD' -or $_.MediaType -eq 4) { 'SSD' } elseif ($_.MediaType -eq 'HDD' -or $_.MediaType -eq 3) { 'HDD' } else { '' }; tamanhoGB = [int][math]::Round($_.Size / 1GB); saude = [string]$_.HealthStatus }
      })
  } catch {}

  $adaptadores = @(Ler-Adaptadores)
  $gateway = ($adaptadores | Where-Object { $_.gateway } | Select-Object -First 1).gateway
  $latGateway = $null
  if ($gateway) { $latGateway = (Medir-Latencia $gateway 3).latenciaMs }
  $internet = Medir-Latencia '8.8.8.8' 3
  $dnsOk = Testar-Dns

  $ramTotalMB = [int][math]::Round($so.TotalVisibleMemorySize / 1024)
  # Diagnostico (desempenho, programas que pesam, eventos do Windows): desliga com "diagnostico": false no config.json.
  $diagnostico = $null
  if ($Cfg -and $Cfg.diagnostico -eq $true) {
    try { $diagnostico = Ler-Diagnostico ([int](($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)) }
    catch { Escrever-Log "Falha no diagnostico: $($_.Exception.Message)" }
  }
  return [ordered]@{
    versao = $VERSAO
    tipo   = 'pc'
    pc     = [ordered]@{
      nome          = $env:COMPUTERNAME
      dominio       = $cs.Domain
      usuario       = [string]$cs.UserName
      so            = [ordered]@{
        nome        = $so.Caption
        versao      = $so.Version
        build       = [string]$so.BuildNumber
        arquitetura = $so.OSArchitecture
        ultimoBoot  = Iso $so.LastBootUpTime
        instaladoEm = Iso $so.InstallDate
      }
      hardware      = [ordered]@{
        fabricante = $cs.Manufacturer
        modelo     = $cs.Model
        serie      = if ($bios) { [string]$bios.SerialNumber } else { '' }
        placaMae   = if ($placa) { ('{0} {1}' -f $placa.Manufacturer, $placa.Product).Trim() } else { '' }
        cpu        = ($cpu | Select-Object -First 1).Name
        nucleos    = [int](($cpu | Measure-Object -Property NumberOfCores -Sum).Sum)
        threads    = [int](($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        ramTotalMB = $ramTotalMB
        gpus       = @($gpus)
      }
      uso           = [ordered]@{
        cpu        = [int](($cpu | Measure-Object -Property LoadPercentage -Average).Average)
        ramLivreMB = [int][math]::Round($so.FreePhysicalMemory / 1024)
        ramTotalMB = $ramTotalMB
      }
      discos        = @($discos)
      discosFisicos = @($fisicos)
      rede          = [ordered]@{
        adaptadores        = @($adaptadores)
        wifi               = $wifi
        wifiVisiveis       = @($visiveis)
        latenciaGatewayMs  = $latGateway
        latenciaInternetMs = $internet.latenciaMs
        perdaInternet      = $internet.perda
        internetOk         = ($internet.perda -lt 100) -and $dnsOk
        dnsOk              = $dnsOk
      }
      impressoras   = @(Ler-Impressoras)
      seguranca     = [ordered]@{ antivirus = @(Ler-Antivirus) }
      uptimeSegundos = [int]((Get-Date) - $so.LastBootUpTime).TotalSeconds
      diagnostico    = $diagnostico
    }
  }
}

# ---------------------------------------------------------------- diagnostico (desempenho, programas, eventos do Windows)
#
# Responde "o computador trava? o que pesa? aguenta o que fazem nele?" sem olhar o que a pessoa faz:
#   - desempenho: rajada de ~5 s com CPU, fila da CPU, disco ocupado, latencia do disco, leituras de
#     memoria no disco (paginacao), memoria comprometida e limite de desempenho do processador;
#   - programas que mais pesaram AGORA: so o NOME do programa, % de CPU e MB de memoria (nunca caminho,
#     linha de comando, titulo de janela, usuario ou conteudo);
#   - eventos do Windows desde o ultimo relatorio: programa que parou de responder, programa que
#     fechou com erro, desligamento inesperado, reinicio (atualizacao/usuario), erro de disco,
#     erro de hardware (WHEA), memoria esgotada e driver de video. So contagens e o nome do programa;
#   - uma vez por hora: saude do disco (temperatura, desgaste, erros), quantidade de programas na
#     inicializacao e o tempo da ultima inicializacao.
# Desliga num computador com  "diagnostico": false  no config.json.

$ARQUIVO_DIAGNOSTICO = Join-Path $PASTA 'diagnostico-estado.json'
$JANELA_EVENTOS_MAXIMA_HORAS = 24

function Nome-DoProcesso([string]$Nome) {
  # "chrome#3" -> "chrome"; tira ".exe". Nada alem do nome do programa.
  $limpo = ([string]$Nome -replace '#\d+$', '' -replace '\.exe$', '').Trim()
  if ($limpo.Length -gt 40) { $limpo = $limpo.Substring(0, 40) }
  return $limpo
}

function Resumir-Processos($Linhas, [int]$Nucleos, [int]$MeuPid = 0) {
  # Junta os processos de mesmo nome (o Chrome tem varios) e devolve os que mais pesam em CPU e
  # em memoria. CPU em % do computador inteiro; memoria em MB privados.
  if ($Nucleos -lt 1) { $Nucleos = 1 }
  $grupos = @{}
  foreach ($l in @($Linhas)) {
    if (-not $l) { continue }
    $nome = Nome-DoProcesso $l.Name
    if (-not $nome -or $nome -eq '_Total' -or $nome -eq 'Idle') { continue }
    if ($MeuPid -gt 0 -and [int]$l.IDProcess -eq $MeuPid) { continue }
    if (-not $grupos.ContainsKey($nome)) { $grupos[$nome] = [pscustomobject]@{ nome = $nome; cpu = 0.0; bytes = 0.0 } }
    $grupos[$nome].cpu += [double]$l.PercentProcessorTime
    $memoria = if ($null -ne $l.WorkingSetPrivate) { [double]$l.WorkingSetPrivate } else { [double]$l.WorkingSet }
    $grupos[$nome].bytes += $memoria
  }
  $todos = @($grupos.Values | ForEach-Object {
      [pscustomobject]@{ nome = $_.nome; cpu = [math]::Min(100.0, [math]::Round($_.cpu / $Nucleos, 1)); memMB = [int][math]::Round($_.bytes / 1MB) }
    })
  $porCpu = @($todos | Where-Object { $_.cpu -ge 1 } | Sort-Object -Property cpu -Descending | Select-Object -First 3)
  $porMemoria = @($todos | Where-Object { $_.memMB -ge 100 } | Sort-Object -Property memMB -Descending | Select-Object -First 3)
  $vistos = @{}
  $saida = @()
  foreach ($p in @($porCpu) + @($porMemoria)) {
    if ($vistos.ContainsKey($p.nome)) { continue }
    $vistos[$p.nome] = $true
    $saida += [ordered]@{ nome = $p.nome; cpu = $p.cpu; memMB = $p.memMB }
  }
  return $saida
}

function Calcular-LatenciaDisco($Antes, $Depois) {
  # Tempo medio por operacao de disco (ms) entre duas leituras brutas (contador PERF_AVERAGE_TIMER).
  if (-not $Antes -or -not $Depois) { return $null }
  $dn = [double]$Depois.AvgDisksecPerTransfer - [double]$Antes.AvgDisksecPerTransfer
  $dd = [double]$Depois.AvgDisksecPerTransfer_Base - [double]$Antes.AvgDisksecPerTransfer_Base
  $f = [double]$Depois.Frequency_PerfTime
  if ($dd -le 0 -or $f -le 0 -or $dn -lt 0) { return $null }
  return [math]::Round(1000 * ($dn / $f) / $dd, 1)
}

function Resumir-Serie($Valores) {
  $validos = @($Valores | Where-Object { $null -ne $_ })
  if (-not $validos.Count) { return $null }
  $m = $validos | Measure-Object -Average -Maximum
  return [pscustomobject]@{ media = [math]::Round([double]$m.Average, 1); max = [math]::Round([double]$m.Maximum, 1) }
}

function Classificar-Reinicio([string]$Processo, $Codigo) {
  # Evento 1074 (reinicio/desligamento pedido): so classifica; o caminho e o usuario NAO sao guardados.
  if ($Processo -match 'TiWorker|TrustedInstaller|wuauclt|MoUsoCoreWorker|USOClient|musnotification|WindowsUpdate') { return 'atualizacao' }
  if ($Processo -match 'explorer|winlogon|shutdown|LogonUI|RuntimeBroker|SystemSettings|StartMenuExperienceHost|ShellExperienceHost') { return 'usuario' }
  return 'outro'
}

function Nome-SeguroDoApp($Valor) {
  # Nome de programa vindo do registro de eventos: so letras, numeros e . _ - + ( ) espaco.
  $texto = ([string]$Valor -replace '[^A-Za-z0-9._+() -]', '').Trim()
  if ($texto.Length -gt 40) { $texto = $texto.Substring(0, 40) }
  return $texto
}

function Agrupar-Eventos($Itens, [int]$Maximo = 30) {
  # Junta eventos iguais (mesmo tipo, programa e detalhe) em um registro com a quantidade e o ultimo horario.
  $grupos = @{}
  foreach ($i in @($Itens)) {
    if (-not $i) { continue }
    $chave = '{0}|{1}|{2}' -f $i.Tipo, $i.App, $i.Detalhe
    if (-not $grupos.ContainsKey($chave)) { $grupos[$chave] = [pscustomobject]@{ tipo = $i.Tipo; app = $i.App; detalhe = $i.Detalhe; vezes = 0; em = $i.Em } }
    $grupos[$chave].vezes += 1
    if ($i.Em -gt $grupos[$chave].em) { $grupos[$chave].em = $i.Em }
  }
  return @($grupos.Values | Sort-Object -Property em -Descending | Select-Object -First $Maximo | ForEach-Object {
      [ordered]@{ tipo = $_.tipo; app = $_.app; detalhe = $_.detalhe; vezes = $_.vezes; em = (Iso $_.em) }
    })
}

function Ler-EstadoDiagnostico {
  $estado = [ordered]@{ ultimaLeitura = ''; ultimaHora = ''; ultimoBoot = '' }
  if (Test-Path $ARQUIVO_DIAGNOSTICO) {
    try {
      $lido = Get-Content $ARQUIVO_DIAGNOSTICO -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($campo in @('ultimaLeitura', 'ultimaHora', 'ultimoBoot')) { if ($lido.$campo) { $estado[$campo] = [string]$lido.$campo } }
    } catch { Escrever-Log "diagnostico-estado.json invalido: $($_.Exception.Message)" }
  }
  return $estado
}

function Gravar-EstadoDiagnostico($Estado) {
  try { [System.IO.File]::WriteAllText($ARQUIVO_DIAGNOSTICO, ($Estado | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) }
  catch { Escrever-Log "Nao consegui gravar diagnostico-estado.json: $($_.Exception.Message)" }
}

function Data-DoEstado([string]$Texto) {
  if (-not $Texto) { return $null }
  try { return [datetime]::Parse($Texto, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch { return $null }
}

function Ler-ContadoresDesempenho {
  # Classes WMI de desempenho (os nomes dos contadores do Get-Counter mudam com o idioma do Windows).
  $r = [ordered]@{}
  try { $r.cpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime } catch {}
  try { $r.filaCpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop).ProcessorQueueLength } catch {}
  try {
    $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
    $r.discoOcupado = [math]::Min(100.0, [math]::Max(0.0, 100.0 - [double]$d.PercentIdleTime))
    $r.filaDisco = [double]$d.CurrentDiskQueueLength
  } catch {}
  try {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    $r.paginasLidas = [double]$m.PagesInputPersec
    $r.comprometida = [double]$m.PercentCommittedBytesInUse
    $r.disponivelMB = [double]$m.AvailableMBytes
  } catch {}
  try {
    $f = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
    if ($null -ne $f.PercentPerformanceLimit) { $r.limiteDesempenho = [double]$f.PercentPerformanceLimit }
    if ($null -ne $f.PercentOfMaximumFrequency) { $r.frequencia = [double]$f.PercentOfMaximumFrequency }
  } catch {}
  return $r
}

function Ler-DiscoBruto {
  try {
    return (Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop | Select-Object AvgDisksecPerTransfer, AvgDisksecPerTransfer_Base, Frequency_PerfTime)
  } catch { return $null }
}

function Medir-Desempenho([int]$Nucleos, [int]$Amostras = 5) {
  # A 1a leitura e descartada: o Windows calcula os contadores formatados desde a leitura anterior.
  [void](Ler-ContadoresDesempenho)
  $processosAntes = $null
  try { $processosAntes = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop } catch {}
  $discoAntes = Ler-DiscoBruto
  $leituras = @()
  for ($i = 0; $i -lt $Amostras; $i++) {
    Start-Sleep -Milliseconds 1000
    $leituras += , (Ler-ContadoresDesempenho)
  }
  $discoDepois = Ler-DiscoBruto
  $processos = @()
  try { $processos = Resumir-Processos (Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop) $Nucleos $PID } catch { Escrever-Log "Diagnostico: processos indisponiveis ($($_.Exception.Message))" }
  $serie = { param([string]$Campo) Resumir-Serie @($leituras | ForEach-Object { if ($_.Contains($Campo)) { $_[$Campo] } }) }
  $cpu = & $serie 'cpu'
  $fila = & $serie 'filaCpu'
  $ocupado = & $serie 'discoOcupado'
  $filaDisco = & $serie 'filaDisco'
  $paginas = & $serie 'paginasLidas'
  $comprometida = & $serie 'comprometida'
  $disponivel = & $serie 'disponivelMB'
  $limite = & $serie 'limiteDesempenho'
  $frequencia = & $serie 'frequencia'
  $desempenho = [ordered]@{ amostras = $leituras.Count }
  if ($cpu) { $desempenho.cpuMedia = $cpu.media; $desempenho.cpuMax = $cpu.max }
  if ($fila) { $desempenho.filaCpuMedia = $fila.media; $desempenho.filaCpuMax = $fila.max }
  if ($ocupado) { $desempenho.discoOcupadoMedia = $ocupado.media; $desempenho.discoOcupadoMax = $ocupado.max }
  if ($filaDisco) { $desempenho.filaDiscoMedia = $filaDisco.media; $desempenho.filaDiscoMax = $filaDisco.max }
  $latencia = Calcular-LatenciaDisco $discoAntes $discoDepois
  if ($null -ne $latencia) { $desempenho.discoLatenciaMs = $latencia }
  if ($paginas) { $desempenho.paginasLidasPorSeg = $paginas.media }
  if ($comprometida) { $desempenho.memoriaComprometidaPct = $comprometida.media }
  if ($disponivel) { $desempenho.memoriaDisponivelMB = [int]$disponivel.media }
  if ($limite) { $desempenho.limiteDesempenhoPct = $limite.max }
  if ($frequencia) { $desempenho.frequenciaPct = $frequencia.media }
  return [pscustomobject]@{ desempenho = $desempenho; processos = @($processos) }
}

function Ler-EventosDoWindows([datetime]$Desde) {
  # Consultas por provedor e numero do evento (nao dependem do idioma). Propriedades, nunca a mensagem.
  $consultas = @(
    @{ Tipo = 'travamento'; Filtro = @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002 }; App = 0 },
    @{ Tipo = 'falha_app'; Filtro = @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000 }; App = 0 },
    @{ Tipo = 'desligamento_inesperado'; Filtro = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 }; App = -1 },
    @{ Tipo = 'desligamento_inesperado_6008'; Filtro = @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6008 }; App = -1 },
    @{ Tipo = 'reinicio'; Filtro = @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074 }; App = -1 },
    @{ Tipo = 'erro_disco'; Filtro = @{ LogName = 'System'; ProviderName = 'disk'; Id = @(7, 11, 15, 51, 52) }; App = -1 },
    @{ Tipo = 'erro_disco'; Filtro = @{ LogName = 'System'; ProviderName = 'Ntfs'; Id = 55 }; App = -1 },
    @{ Tipo = 'erro_disco'; Filtro = @{ LogName = 'System'; ProviderName = @('storahci', 'stornvme'); Id = 129 }; App = -1 },
    @{ Tipo = 'erro_hardware'; Filtro = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = @(17, 18, 19, 20, 47) }; App = -1 },
    @{ Tipo = 'memoria_esgotada'; Filtro = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004 }; App = -1 },
    @{ Tipo = 'driver_video'; Filtro = @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101 }; App = -1 }
  )
  $itens = @()
  foreach ($c in $consultas) {
    $filtro = $c.Filtro.Clone()
    $filtro.StartTime = $Desde
    $encontrados = @()
    try { $encontrados = @(Get-WinEvent -FilterHashtable $filtro -MaxEvents 200 -ErrorAction Stop) }
    catch {
      if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { Escrever-Log "Diagnostico: eventos '$($c.Tipo)' indisponiveis ($($_.Exception.Message))" }
      continue
    }
    foreach ($e in $encontrados) {
      $app = ''
      $detalhe = ''
      $tipo = $c.Tipo
      try {
        if ($c.App -ge 0 -and $e.Properties.Count -gt $c.App) { $app = Nome-SeguroDoApp $e.Properties[$c.App].Value }
        if ($tipo -eq 'reinicio') { $detalhe = Classificar-Reinicio ([string]$e.Properties[0].Value) $e.Properties[3].Value }
        elseif ($tipo -eq 'erro_disco' -or $tipo -eq 'erro_hardware') { $detalhe = '{0}:{1}' -f (Nome-SeguroDoApp $e.ProviderName), $e.Id }
      } catch {}
      $itens += [pscustomobject]@{ Tipo = $tipo; App = $app; Detalhe = $detalhe; Em = $e.TimeCreated }
    }
  }
  # 6008 e 41 descrevem o mesmo desligamento: so conta o 6008 quando nao ha 41.
  if (@($itens | Where-Object { $_.Tipo -eq 'desligamento_inesperado' }).Count -gt 0) {
    $itens = @($itens | Where-Object { $_.Tipo -ne 'desligamento_inesperado_6008' })
  } else {
    foreach ($i in @($itens | Where-Object { $_.Tipo -eq 'desligamento_inesperado_6008' })) { $i.Tipo = 'desligamento_inesperado' }
  }
  return @(Agrupar-Eventos $itens 30)
}

function Ler-InicioDoWindows($Estado) {
  # Duracao da ultima inicializacao (Diagnostics-Performance, evento 100). So devolve se for nova.
  try {
    $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
    $em = Iso $e.TimeCreated
    if ($em -eq $Estado.ultimoBoot) { return $null }
    $xml = [xml]$e.ToXml()
    $ms = [double](($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text')
    if ($ms -le 0) { return $null }
    $Estado.ultimoBoot = $em
    return [ordered]@{ duracaoSegundos = [int][math]::Round($ms / 1000); em = $em }
  } catch { return $null }
}

function Ler-SaudeDosDiscos {
  $lista = @()
  try {
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
      $c = $null
      try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
      if (-not $c) { continue }
      $lista += [ordered]@{
        modelo       = (Nome-SeguroDoApp $d.FriendlyName)
        temperaturaC = if ($null -ne $c.Temperature) { [int]$c.Temperature } else { $null }
        desgastePct  = if ($null -ne $c.Wear) { [int]$c.Wear } else { $null }
        errosLeitura = if ($null -ne $c.ReadErrorsTotal) { [int64]$c.ReadErrorsTotal } else { $null }
        errosEscrita = if ($null -ne $c.WriteErrorsTotal) { [int64]$c.WriteErrorsTotal } else { $null }
        horasLigado  = if ($null -ne $c.PowerOnHours) { [int64]$c.PowerOnHours } else { $null }
      }
    }
  } catch {}
  return $lista
}

function Reinicio-Pendente {
  foreach ($caminho in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
    try { if (Test-Path $caminho) { return $true } } catch {}
  }
  return $false
}

function Ler-Diagnostico([int]$Nucleos) {
  # Devolve o diagnostico e deixa o novo estado em $script:EstadoDiagnosticoNovo (so gravado depois que o portal confirma o envio).
  $estado = Ler-EstadoDiagnostico
  $agora = Get-Date
  $desde = Data-DoEstado $estado.ultimaLeitura
  if (-not $desde -or $desde -lt $agora.AddHours(-$JANELA_EVENTOS_MAXIMA_HORAS)) { $desde = $agora.AddHours(-$JANELA_EVENTOS_MAXIMA_HORAS) }
  if ($desde -gt $agora) { $desde = $agora.AddMinutes(-5) }

  $diag = [ordered]@{ versao = 1; coletadoEm = (Iso $agora) }
  try {
    $medido = Medir-Desempenho $Nucleos 5
    $diag.desempenho = $medido.desempenho
    $diag.processos = @($medido.processos)
  } catch { Escrever-Log "Diagnostico: desempenho indisponivel ($($_.Exception.Message))" }
  try { $diag.eventos = @(Ler-EventosDoWindows $desde) } catch { Escrever-Log "Diagnostico: eventos indisponiveis ($($_.Exception.Message))" }
  $diag.reinicioPendente = Reinicio-Pendente

  $ultimaHora = Data-DoEstado $estado.ultimaHora
  if (-not $ultimaHora -or $ultimaHora -lt $agora.AddMinutes(-60)) {
    $inicio = Ler-InicioDoWindows $estado
    if ($inicio) { $diag.boot = $inicio }
    $discos = @(Ler-SaudeDosDiscos)
    if ($discos.Count) { $diag.discos = $discos }
    try { $diag.programasNaInicializacao = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop).Count } catch {}
    $estado.ultimaHora = (Iso $agora)
  }
  $estado.ultimaLeitura = (Iso $agora)
  $script:EstadoDiagnosticoNovo = $estado
  return $diag
}

# ---------------------------------------------------------------- varredura (computador coletor)

$PORTAS = @(21, 22, 23, 53, 80, 135, 139, 443, 445, 515, 554, 631, 3389, 8080, 9100)

$OID = @{
  sysDescr     = '.1.3.6.1.2.1.1.1.0'
  sysUpTime    = '.1.3.6.1.2.1.1.3.0'
  sysName      = '.1.3.6.1.2.1.1.5.0'
  sysLocation  = '.1.3.6.1.2.1.1.6.0'
  modelo       = '.1.3.6.1.2.1.25.3.2.1.3.1'
  statusImp    = '.1.3.6.1.2.1.25.3.5.1.1.1'
  statusDisp   = '.1.3.6.1.2.1.25.3.2.1.5.1'
  errosImp     = '.1.3.6.1.2.1.25.3.5.1.2.1'
  paginas      = '.1.3.6.1.2.1.43.10.2.1.4.1.1'
  serie        = '.1.3.6.1.2.1.43.5.1.1.17.1'
  supDescricao = '.1.3.6.1.2.1.43.11.1.1.6.1.'
  supMaximo    = '.1.3.6.1.2.1.43.11.1.1.8.1.'
  supNivel     = '.1.3.6.1.2.1.43.11.1.1.9.1.'
}

# hrPrinterDetectedErrorState (RFC 3805): bits do 1o e do 2o byte
$ERROS_IMPRESSORA = @(
  @{ byte = 0; bit = 0x80; codigo = 'pouco_papel' }, @{ byte = 0; bit = 0x40; codigo = 'sem_papel' },
  @{ byte = 0; bit = 0x20; codigo = 'toner_baixo' }, @{ byte = 0; bit = 0x10; codigo = 'sem_toner' },
  @{ byte = 0; bit = 0x08; codigo = 'porta_aberta' }, @{ byte = 0; bit = 0x04; codigo = 'atolada' },
  @{ byte = 0; bit = 0x02; codigo = 'offline' }, @{ byte = 0; bit = 0x01; codigo = 'manutencao' },
  @{ byte = 1; bit = 0x80; codigo = 'bandeja_ausente' }, @{ byte = 1; bit = 0x08; codigo = 'saida_cheia' },
  @{ byte = 1; bit = 0x04; codigo = 'bandeja_vazia' }
)

function Abrir-Snmp([string]$Ip, [string]$Comunidade, [int]$Tentativas) {
  try {
    $snmp = New-Object -ComObject olePrn.OleSNMP
    $snmp.Open($Ip, $Comunidade, $Tentativas, 1000)
    return $snmp
  } catch { return $null }
}
function Ler-Oid($Snmp, [string]$Oid) {
  try { return $Snmp.Get($Oid) } catch { return $null }
}
function Numero-Snmp($Valor) {
  # Resposta vazia (a impressora demorou) nao pode virar 0: seria um falso "toner acabando".
  if ($null -ne $Valor -and [string]$Valor -match '^-?\d+(\.\d+)?$') { return [double]$Valor }
  return $null
}

function Ler-Snmp([string]$Ip, [string]$Comunidade, [bool]$Impressora) {
  # Impressora ganha uma segunda tentativa (os dados dela importam); nos outros aparelhos, quem
  # tem SNMP responde em menos de 1 s, e cada um sem SNMP custaria o dobro do tempo.
  $snmp = Abrir-Snmp $Ip $Comunidade $(if ($Impressora) { 1 } else { 0 })
  if (-not $snmp) { return $null }
  try {
    # Sem resposta ao primeiro pedido, o aparelho nao tem SNMP: nao espera pelos outros.
    $nome = Ler-Oid $snmp $OID.sysName
    if ($null -eq $nome) { return $null }
    $descricao = Ler-Oid $snmp $OID.sysDescr
    $uptime = Ler-Oid $snmp $OID.sysUpTime
    $resultado = [ordered]@{
      snmp = [ordered]@{
        nome           = [string]$nome
        descricao      = [string]$descricao
        local          = [string](Ler-Oid $snmp $OID.sysLocation)
        uptimeSegundos = if ($uptime -as [double]) { [int]([double]$uptime / 100) } else { $null }
      }
      impressora = $null
    }
    if ($Impressora) {
      $alertas = New-Object System.Collections.ArrayList
      $erros = Ler-Oid $snmp $OID.errosImp
      if ($erros) {
        if ($erros -is [array]) { $bytes = @([int[]]$erros) } else { $bytes = @([int[]][char[]][string]$erros) }
        foreach ($e in $ERROS_IMPRESSORA) {
          if ($bytes.Count -gt $e.byte -and ($bytes[$e.byte] -band $e.bit)) { [void]$alertas.Add($e.codigo) }
        }
      }
      $suprimentos = @()
      for ($n = 1; $n -le 10; $n++) {
        $desc = Ler-Oid $snmp ($OID.supDescricao + $n)
        if ($null -eq $desc -or [string]$desc -eq '') { break }
        $maximo = Numero-Snmp (Ler-Oid $snmp ($OID.supMaximo + $n))
        $nivel = Numero-Snmp (Ler-Oid $snmp ($OID.supNivel + $n))
        $percentual = $null
        if ($null -ne $maximo -and $null -ne $nivel -and $maximo -gt 0 -and $nivel -ge 0) { $percentual = [int][math]::Min(100, [math]::Round(100 * $nivel / $maximo)) }
        if ($null -ne $percentual -and $percentual -le 10 -and [string]$desc -match 'toner|cartucho|cartridge|ink|tinta|black|preto|cyan|magenta|yellow|amarelo' -and -not $alertas.Contains('toner_baixo')) { [void]$alertas.Add('toner_baixo') }
        # A Xerox manda "Black Toner Cartridge,  Replace with PN ...;SN ...": fica so o nome.
        $nomeSuprimento = ((([string]$desc).Trim([char]0)) -split '[,;]')[0].Trim()
        $suprimentos += [ordered]@{ nome = $nomeSuprimento; percentual = $percentual }
      }
      $statusCodigo = Ler-Oid $snmp $OID.statusImp
      $status = switch ([string]$statusCodigo) { '3' { 'ocioso' } '4' { 'imprimindo' } '5' { 'aquecendo' } default { 'desconhecido' } }
      if ($status -eq 'desconhecido') {
        # Algumas (Xerox) respondem "outro" aqui; o estado geral do aparelho ainda diz se esta funcionando.
        $status = switch ([string](Ler-Oid $snmp $OID.statusDisp)) { '2' { 'ocioso' } '5' { 'erro' } default { 'desconhecido' } }
      }
      if ($alertas | Where-Object { @('sem_papel', 'sem_toner', 'porta_aberta', 'atolada', 'offline') -contains $_ }) { $status = 'erro' }
      $resultado.impressora = [ordered]@{
        modelo      = [string](Ler-Oid $snmp $OID.modelo)
        serie       = [string](Ler-Oid $snmp $OID.serie)
        status      = $status
        alertas     = @($alertas)
        paginas     = Numero-Snmp (Ler-Oid $snmp $OID.paginas)
        suprimentos = @($suprimentos)
      }
    }
    return $resultado
  } finally {
    try { $snmp.Close() } catch {}
  }
}

function Montar-Varredura($Cfg) {
  $inicio = Get-Date
  $adaptadores = @(Ler-Adaptadores)
  $principal = $adaptadores | Where-Object { $_.gateway -and $_.ipv4 } | Select-Object -First 1
  $meuIp = if ($principal) { $principal.ipv4[0] } else { '' }
  $gateway = if ($principal) { $principal.gateway } else { '' }

  $redes = @($Cfg.redes | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' })
  if (-not $redes -and $principal) {
    # Sem redes no config: a rede do proprio coletor (no maximo /24, para nao varrer milhares de enderecos).
    $prefixo = [math]::Max([int]$principal.prefixo, 24)
    $redes = @(Rede-DoIp $meuIp $prefixo)
  }
  $alvos = @($redes | ForEach-Object { Ips-DaRede $_ } | Select-Object -Unique | Select-Object -First 1024)
  Escrever-Log ("Varrendo {0} enderecos em {1}" -f $alvos.Count, ($redes -join ', '))

  # Com centenas de pings de uma vez, aparelho lento (Wi-Fi) responde depois do prazo. Na segunda
  # rodada, so para quem ficou calado, o endereco ja esta resolvido e ele responde na hora.
  $pings = Medir-Pings $alvos 1000
  $calados = @($alvos | Where-Object { -not $pings.ContainsKey($_) })
  $segunda = Medir-Pings $calados 1000
  foreach ($ip in $segunda.Keys) { $pings[$ip] = $segunda[$ip] }
  Start-Sleep -Milliseconds 500
  $vizinhos = @{}
  foreach ($v in @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    if ($alvos -notcontains $v.IPAddress) { continue }
    $mac = Formatar-Mac $v.LinkLayerAddress
    if (-not $mac -or $mac -like '01:00:5E*' -or $mac -eq 'FF:FF:FF:FF:FF:FF') { continue }
    if (@('Reachable', 'Stale', 'Delay', 'Probe', 'Permanent') -notcontains [string]$v.State) { continue }
    $vizinhos[$v.IPAddress] = [pscustomobject]@{ Mac = $mac; Alcancavel = ([string]$v.State -eq 'Reachable') }
  }

  # Online: respondeu ao ping ou ao ARP agora (Windows com firewall nao responde ping, mas responde ARP).
  $online = @($alvos | Where-Object { $pings.ContainsKey($_) -or ($vizinhos.ContainsKey($_) -and $vizinhos[$_].Alcancavel) })
  if ($meuIp -and $online -notcontains $meuIp) { $online += $meuIp }
  $portas = Testar-Portas $online $PORTAS 800
  $nomes = Resolver-Nomes $online 2500

  $dispositivos = @()
  foreach ($ip in $online) {
    $abertas = @(); if ($portas.ContainsKey($ip)) { $abertas = @($portas[$ip] | Sort-Object) }
    $mac = ''
    if ($vizinhos.ContainsKey($ip)) { $mac = $vizinhos[$ip].Mac }
    if ($ip -eq $meuIp -and $principal) { $mac = Formatar-Mac $principal.mac }
    $ehImpressora = [bool]($abertas | Where-Object { @(9100, 515, 631) -contains $_ })
    $ehEquipamentoDeRede = ($ip -eq $gateway) -or (($abertas | Where-Object { @(80, 443, 22, 23) -contains $_ }) -and -not ($abertas | Where-Object { @(135, 139, 445, 3389) -contains $_ }))
    $leitura = $null
    if ($ehImpressora -or $ehEquipamentoDeRede) { $leitura = Ler-Snmp $ip $Cfg.snmpComunidade $ehImpressora }
    $dispositivos += [ordered]@{
      ip            = $ip
      mac           = $mac
      nomeDns       = if ($nomes.ContainsKey($ip)) { $nomes[$ip] } else { '' }
      latenciaMs    = if ($pings.ContainsKey($ip)) { $pings[$ip] } else { $null }
      respondeuPing = $pings.ContainsKey($ip)
      portas        = @($abertas)
      gateway       = ($ip -eq $gateway)
      coletor       = ($ip -eq $meuIp)
      snmp          = if ($leitura) { $leitura.snmp } else { $null }
      impressora    = if ($leitura) { $leitura.impressora } else { $null }
    }
  }

  # Internet: ping em dois servidores, DNS, uma pagina pequena e o IP publico.
  $google = Medir-Latencia '8.8.8.8' 4
  $cloudflare = Medir-Latencia '1.1.1.1' 4
  $melhor = @($google, $cloudflare) | Where-Object { $null -ne $_.latenciaMs } | Sort-Object latenciaMs | Select-Object -First 1
  $dnsOk = Testar-Dns
  $httpOk = $false
  try { $httpOk = (Invoke-WebRequest -Uri 'http://www.gstatic.com/generate_204' -UseBasicParsing -TimeoutSec 6).StatusCode -eq 204 } catch {}
  $ipPublico = ''
  try { $ipPublico = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 6).ip } catch {}
  $latGateway = $null
  if ($gateway) { $latGateway = (Medir-Latencia $gateway 3).latenciaMs }

  return [ordered]@{
    versao       = $VERSAO
    tipo         = 'rede'
    coletor      = [ordered]@{
      nome            = $env:COMPUTERNAME
      ip              = $meuIp
      redes           = @($redes)
      duracaoSegundos = [math]::Round(((Get-Date) - $inicio).TotalSeconds, 1)
    }
    internet     = [ordered]@{
      ok                = ($httpOk -or ($dnsOk -and $melhor))
      latenciaMs        = if ($melhor) { $melhor.latenciaMs } else { $null }
      perda             = [int][math]::Round(($google.perda + $cloudflare.perda) / 2)
      dnsOk             = $dnsOk
      httpOk            = $httpOk
      ipPublico         = $ipPublico
      gateway           = $gateway
      latenciaGatewayMs = $latGateway
    }
    dispositivos = @($dispositivos)
  }
}

# ---------------------------------------------------------------- uso de sites

function Ler-UsoDosSites([bool]$Habilitado = $false) {
  if (-not $Habilitado) { return $null }
  # Junta o uso de HOJE que o vigia da sessao (svt-uso.ps1) ja apurou e gravou. Nao observa nada aqui;
  # so repassa. Apaga os arquivos de dias anteriores (ja foram enviados ao longo daquele dia).
  $pastaUso = Join-Path $PASTA 'uso'
  if (-not (Test-Path $pastaUso)) { return $null }
  $hoje = (Get-Date).ToString('yyyy-MM-dd')
  $porSite = [ordered]@{}
  foreach ($arq in @(Get-ChildItem $pastaUso -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $dados = $null
    try { $dados = Get-Content $arq.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if (-not $dados) { continue }
    if ([string]$dados.dia -ne $hoje) { Remove-Item $arq.FullName -Force -ErrorAction SilentlyContinue; continue }
    foreach ($s in @($dados.sites)) {
      if (-not $s.site) { continue }
      $tipo = if ($s.tipo -in @('dominio', 'estado')) { [string]$s.tipo } else { '' }
      $detalhe = [string]$s.detalhe   # so nome de programa fora da lista ou navegador:motivo (nunca titulo ou caminho)
      $chave = "${tipo}:$($s.site)|$detalhe"
      if (-not $porSite.Contains($chave)) {
        $porSite[$chave] = [ordered]@{ site = [string]$s.site; tipo = $tipo; detalhe = $detalhe; categoria = [string]$s.categoria; segundos = 0; segmentos = (New-Object System.Collections.ArrayList) }
      }
      $e = $porSite[$chave]
      $e.segundos += [int]$s.segundos
      foreach ($seg in @($s.segmentos)) {
        if ($seg.de -and $seg.ate) { [void]$e.segmentos.Add([ordered]@{ de = [string]$seg.de; ate = [string]$seg.ate }) }
      }
    }
  }
  if ($porSite.Count -eq 0) { return $null }
  $sites = @()
  foreach ($k in $porSite.Keys) {
    $e = $porSite[$k]
    $segs = @($e.segmentos | Sort-Object { $_.de } | Select-Object -First 240)
    $registro = [ordered]@{ site = $e.site; categoria = $e.categoria; segundos = $e.segundos; segmentos = $segs }
    if ($e.tipo) { $registro.tipo = $e.tipo }
    if ($e.detalhe) { $registro.detalhe = $e.detalhe }
    $sites += $registro
  }
  return [ordered]@{ dia = $hoje; sites = $sites }
}

function Guardar-SitesVigiados($vigilancia) {
  # Grava a lista de sites + liga/desliga que o portal mandou, para o vigia da sessao (usuario comum) ler.
  # So nomes de sites e palavras-chave; nao tem segredo, entao pode ser lido pelo usuario.
  if (-not $vigilancia) { return }
  try {
    [System.IO.File]::WriteAllText((Join-Path $PASTA 'sites-vigiados.json'), ($vigilancia | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  } catch { Escrever-Log "Nao consegui gravar sites-vigiados.json: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- envio

function Enviar($Relatorio, $Cfg) {
  if ($Relatorio.tipo -eq 'pc') {
    $Relatorio.coletaUso = $Cfg.coletarUso -eq $true
    if ($Relatorio.coletaUso) { $Relatorio.uso = Ler-UsoDosSites -Habilitado $true }
    else { $Relatorio.Remove('uso') }
  }
  $json = $Relatorio | ConvertTo-Json -Depth 10 -Compress
  if ($Teste) {
    Write-Output ($Relatorio | ConvertTo-Json -Depth 10)
    return $null
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $resposta = Invoke-RestMethod -Method Post -Uri $Cfg.url -Body $bytes -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $($Cfg.token)" } -TimeoutSec 60
  Escrever-Log ("Enviado ({0}): {1}" -f $Relatorio.tipo, ($resposta | ConvertTo-Json -Compress))
  return $resposta
}

$cfg = Ler-Config
if (-not $Teste -and (-not $cfg.url -or -not $cfg.token)) {
  Escrever-Log 'config.json sem url ou token: reinstale o agente pelo instalar.ps1.'
  exit 1
}

try {
  $resposta = Enviar (Montar-RelatorioPc $cfg) $cfg
  if ($Teste -and $resposta) { Write-Output $resposta }   # no -Teste, Enviar devolve o JSON em vez de enviar
  # So avanca a janela dos eventos depois que o portal confirmou o envio (senao a proxima rodada repete).
  if (-not $Teste -and $resposta -and $resposta.historicoGravado -eq $true -and $script:EstadoDiagnosticoNovo) { Gravar-EstadoDiagnostico $script:EstadoDiagnosticoNovo }
  if ($cfg.coletarUso -eq $true -and $resposta -and $resposta.vigilancia) { Guardar-SitesVigiados $resposta.vigilancia }
}
catch { Escrever-Log "Falha no relatorio do computador: $($_.Exception.Message)" }

if ($cfg.coletor) {
  try { Enviar (Montar-Varredura $cfg) $cfg }
  catch { Escrever-Log "Falha na varredura da rede: $($_.Exception.Message)" }
}
