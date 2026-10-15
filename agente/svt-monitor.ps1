<#
  SVT Monitor - agente de monitoramento do Portal Interno SVT (modulo Infraestrutura)

  Cada computador manda, a cada 5 minutos (tarefa agendada criada pelo instalar.ps1):
    hardware, uso de CPU/RAM/disco, rede (cabo ou Wi-Fi, sinal, velocidade), latencia ate o
    roteador e a internet, impressoras instaladas e antivirus.
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
$VERSAO = '2.1.0'
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
  $cfg = [ordered]@{ url = ''; token = ''; coletor = $false; redes = @(); snmpComunidade = 'public' }
  if (Test-Path $Config) {
    try {
      $lido = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($campo in @('url', 'token', 'coletor', 'redes', 'snmpComunidade')) {
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

function Montar-RelatorioPc {
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
    }
  }
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

# ---------------------------------------------------------------- envio

function Enviar($Relatorio, $Cfg) {
  $json = $Relatorio | ConvertTo-Json -Depth 10 -Compress
  if ($Teste) {
    Write-Output ($Relatorio | ConvertTo-Json -Depth 10)
    return
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $resposta = Invoke-RestMethod -Method Post -Uri $Cfg.url -Body $bytes -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $($Cfg.token)" } -TimeoutSec 60
  Escrever-Log ("Enviado ({0}): {1}" -f $Relatorio.tipo, ($resposta | ConvertTo-Json -Compress))
}

$cfg = Ler-Config
if (-not $Teste -and (-not $cfg.url -or -not $cfg.token)) {
  Escrever-Log 'config.json sem url ou token: reinstale o agente pelo instalar.ps1.'
  exit 1
}

try { Enviar (Montar-RelatorioPc) $cfg }
catch { Escrever-Log "Falha no relatorio do computador: $($_.Exception.Message)" }

if ($cfg.coletor) {
  try { Enviar (Montar-Varredura $cfg) $cfg }
  catch { Escrever-Log "Falha na varredura da rede: $($_.Exception.Message)" }
}
