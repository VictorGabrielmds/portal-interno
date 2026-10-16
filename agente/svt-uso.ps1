<#
  svt-uso.ps1 - vigia, na sessao do proprio usuario, o tempo em sites e programas de uma lista.

  So deve rodar com o aceite dos funcionarios (termo assinado). NAO le senhas, NAO le o que foi
  digitado, NAO le conversas, NAO le o conteudo das paginas e NAO tira foto da tela. Faz uma coisa
  so: a cada poucos segundos, olha o que esta na frente e verifica se bate com a lista que a
  administracao configurou no portal. Reconhece de tres formas, conforme a lista:
    - por DOMINIO do site (consulta apenas a barra de endereco para reconhecer o item;
      nao grava o dominio nem o resto do link, a pagina ou o conteudo);
    - por PROGRAMA aberto (ex.: Excel, Word, WhatsApp);
    - por PALAVRA no titulo da aba.
  O que nao esta na lista nao e registrado de forma alguma. Guarda so o NOME do item (ex.: "GFlex") e
  o tempo. Grava em C:\ProgramData\SVT-Monitor\uso\<usuario>-<dia>.json; o agente de sistema envia.
  Fica desligado enquanto o portal nao mandar ligar. Instalado pela tarefa "SVT Monitor - Uso".
#>
param(
  [string]$Pasta = (Join-Path $env:ProgramData 'SVT-Monitor'),
  [string]$TesteTitulo = '',
  [string]$TesteProcesso = '',
  [string]$TesteUrl = ''
)

$ErrorActionPreference = 'Stop'
$NAVEGADORES = @('chrome', 'msedge', 'firefox', 'opera', 'opera_gx', 'brave', 'vivaldi', 'iexplore')

# Lista usada so se o portal ainda nao tiver mandado a dele. A de verdade vem de sites-vigiados.json.
$SITES_PADRAO = @(
  [ordered]@{ nome = 'YouTube'; categoria = 'Video'; palavras = @('youtube'); dominios = @('youtube.com'); processos = @() },
  [ordered]@{ nome = 'Netflix'; categoria = 'Video'; palavras = @('netflix'); dominios = @('netflix.com'); processos = @() },
  [ordered]@{ nome = 'Instagram'; categoria = 'Rede social'; palavras = @('instagram'); dominios = @('instagram.com'); processos = @() },
  [ordered]@{ nome = 'Facebook'; categoria = 'Rede social'; palavras = @('facebook'); dominios = @('facebook.com'); processos = @() },
  [ordered]@{ nome = 'TikTok'; categoria = 'Rede social'; palavras = @('tiktok'); dominios = @('tiktok.com'); processos = @() },
  [ordered]@{ nome = 'Shopee'; categoria = 'Compras'; palavras = @('shopee'); dominios = @('shopee.com.br'); processos = @() },
  [ordered]@{ nome = 'Mercado Livre'; categoria = 'Compras'; palavras = @('mercado livre'); dominios = @('mercadolivre.com.br'); processos = @() },
  [ordered]@{ nome = 'GFlex'; categoria = 'Trabalho'; palavras = @(); dominios = @('gflex.inforgeneses.com.br'); processos = @() },
  [ordered]@{ nome = 'EnsineFlex'; categoria = 'Trabalho'; palavras = @(); dominios = @('ensineflex.inforgeneses.com.br'); processos = @() },
  [ordered]@{ nome = 'eLibro'; categoria = 'Trabalho'; palavras = @(); dominios = @('elibro.net'); processos = @() },
  [ordered]@{ nome = 'Portal SVT'; categoria = 'Trabalho'; palavras = @(); dominios = @('portal.svtfaculdade.edu.br'); processos = @() },
  [ordered]@{ nome = 'HostGator'; categoria = 'Trabalho'; palavras = @(); dominios = @('br168.hostgator.com.br'); processos = @() },
  [ordered]@{ nome = 'TotalBank'; categoria = 'Trabalho'; palavras = @(); dominios = @('totalbank.com.br'); processos = @() },
  [ordered]@{ nome = 'Gmail'; categoria = 'Comunicacao'; palavras = @(); dominios = @('mail.google.com'); processos = @() },
  [ordered]@{ nome = 'WhatsApp'; categoria = 'Comunicacao'; palavras = @(); dominios = @('web.whatsapp.com'); processos = @('whatsapp') },
  [ordered]@{ nome = 'Excel'; categoria = 'Trabalho'; palavras = @(); dominios = @(); processos = @('excel') },
  [ordered]@{ nome = 'Word'; categoria = 'Trabalho'; palavras = @(); dominios = @(); processos = @('winword') }
)

# API do Windows: janela da frente (o titulo), o processo dono, e ha quanto tempo o usuario nao mexe.
$SIG = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SvtUso {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  public static IntPtr Frente() { return GetForegroundWindow(); }
  public static uint Pid(IntPtr h) { uint p = 0; GetWindowThreadProcessId(h, out p); return p; }
  public static string Titulo(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
  public static uint OciosoMs() {
    var li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
    if (!GetLastInputInfo(ref li)) return 0;
    return (uint)Environment.TickCount - li.dwTime;
  }
}
'@
try { if (-not ('SvtUso' -as [type])) { Add-Type -TypeDefinition $SIG -ErrorAction Stop } } catch {}

# Leitura do endereco da aba do navegador (so para casar com os dominios da lista): usa a camada de
# acessibilidade do Windows (UI Automation). Se nao estiver disponivel, o dominio simplesmente nao
# e lido (os itens por programa e por titulo continuam funcionando).
$UIA_OK = $false
try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop; $UIA_OK = $true } catch { $UIA_OK = $false }

function Host-DaUrl([string]$u) {
  $u = ([string]$u).Trim()
  if (-not $u -or $u -match '\s') { return '' }
  if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    # Barras podem omitir https://, inclusive em webmail com porta (host:2096).
    if ($u -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -and $u -notmatch '^[^/?#:\s]+:\d+([/?#]|$)') { return '' }
    $u = 'https://' + $u
  }
  $uri = $null
  if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { return '' }
  if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) { return '' }
  return $uri.DnsSafeHost.ToLowerInvariant().TrimEnd('.')
}

function Eh-BarraDeEndereco([string]$id, [string]$nome) {
  # IDs conhecidos e nomes de acessibilidade da interface do navegador (pt/en).
  if ($id -in @('addressEditBox', 'urlbar-input', 'urlbar', 'omnibox')) { return $true }
  $n = ($nome.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').ToLowerInvariant()
  return $n -match '^(address and search bar|address bar|search or enter (web )?address|barra de enderecos?( e (de )?pesquisa)?|pesquisar ou (inserir|digitar) endereco|search with .+ or enter address|pesquisar com .+ ou (digitar|introduzir) endereco)$'
}

function Ler-HostDaJanela($h) {
  # Devolve so o dominio (host) da aba ativa, ou ''. Nunca guarda o endereco completo.
  if (-not $UIA_OK) { return '' }
  try {
    $raiz = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    if (-not $raiz) { return '' }
    # Percorre somente a interface do navegador; NUNCA entra no documento da pagina.
    # Buscar todos os Edit descendentes pode confundir formularios/emails com a barra de endereco.
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $fila = New-Object System.Collections.Queue
    $fila.Enqueue($raiz)
    $vistos = 0
    while ($fila.Count -and $vistos -lt 400) {
      $e = $fila.Dequeue(); $vistos++
      $info = $e.Current
      if ($info.ControlType -eq [System.Windows.Automation.ControlType]::Document) { continue }
      if ($info.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and (Eh-BarraDeEndereco $info.AutomationId $info.Name)) {
        # Texto ainda sendo digitado nao e uma pagina visitada.
        if ($info.HasKeyboardFocus) { return '' }
        $vp = $null
        if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
          return (Host-DaUrl $vp.Current.Value)
        }
      }
      $filho = $walker.GetFirstChild($e)
      while ($filho -and ($fila.Count + $vistos) -lt 400) {
        $fila.Enqueue($filho)
        $filho = $walker.GetNextSibling($filho)
      }
    }
  } catch {}
  return ''
}

function Site-DaJanela([string]$titulo, [string]$processo, [string]$hostAtual, $sites) {
  # Devolve o item da lista que corresponde ao que esta na frente, ou $null.
  $p = ($processo.Trim() -replace '\.exe$', '').ToLowerInvariant()
  $ehNavegador = $NAVEGADORES -contains $p
  # 1) por programa (Excel, Word, WhatsApp...) - independe de navegador.
  foreach ($s in $sites) { foreach ($proc in @($s.processos)) {
    if ($proc -and $p -eq (([string]$proc).Trim() -replace '\.exe$', '').ToLowerInvariant()) { return $s }
  } }
  if (-not $ehNavegador) { return $null }
  # 2) por dominio do site (so o host, que ja veio sem o resto do link).
  $hostAtual = Host-DaUrl $hostAtual
  if ($hostAtual) {
    foreach ($s in $sites) {
      foreach ($d in @($s.dominios)) {
        $dom = Host-DaUrl ([string]$d)
        if ($dom -and ($hostAtual -eq $dom -or $hostAtual.EndsWith('.' + $dom))) { return $s }
      }
    }
  }
  # 3) Compatibilidade com listas antigas por titulo. Um dominio conhecido diferente nao pode
  # virar YouTube, por exemplo, so porque a pagina de busca menciona esse nome.
  $t = $titulo.ToLower()
  foreach ($s in $sites) {
    if ($hostAtual -and @($s.dominios | Where-Object { $_ }).Count) { continue }
    foreach ($palavra in @($s.palavras)) { if ($palavra -and $t.Contains(([string]$palavra).ToLower())) { return $s } }
  }
  return $null
}

function Ler-Sites {
  $cfg = [ordered]@{ ativo = $false; idleSegundos = 90; amostraSegundos = 25; sites = $SITES_PADRAO }
  $arq = Join-Path $Pasta 'sites-vigiados.json'
  if (Test-Path $arq) {
    try {
      $lido = Get-Content $arq -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $lido.ativo) { $cfg.ativo = [bool]$lido.ativo }
      if ($lido.idleSegundos) { $cfg.idleSegundos = [int]$lido.idleSegundos }
      if ($lido.amostraSegundos) { $cfg.amostraSegundos = [int]$lido.amostraSegundos }
      if ($null -ne $lido.sites) {
        $cfg.sites = @($lido.sites | Where-Object { $_.nome } | ForEach-Object {
            [ordered]@{
              nome = [string]$_.nome
              categoria = [string]$_.categoria
              palavras = @($_.palavras)
              dominios = @($_.dominios)
              processos = @($_.processos)
            }
          } | Where-Object { @($_.palavras).Count -or @($_.dominios).Count -or @($_.processos).Count })
      }
    } catch {}
  }
  if ($cfg.amostraSegundos -lt 5) { $cfg.amostraSegundos = 5 }
  return $cfg
}

# Modo teste: casa valores dados (nao le a tela, nao grava nada) e sai.
if ($TesteTitulo -or $TesteProcesso -or $TesteUrl) {
  $s = Site-DaJanela $TesteTitulo $TesteProcesso (Host-DaUrl $TesteUrl) (Ler-Sites).sites
  if ($s) { Write-Output ("ITEM: {0} [{1}]" -f $s.nome, $s.categoria) } else { Write-Output 'ITEM: (nenhum)' }
  exit 0
}

$pastaUso = Join-Path $Pasta 'uso'
$usuario = ($env:USERNAME -replace '[^A-Za-z0-9._-]', '_')
if (-not $usuario) { $usuario = 'usuario' }
$arquivoDe = { param($dia) Join-Path $pastaUso ("{0}-{1}.json" -f $usuario, $dia) }

$estado = @{}
$diaAtual = (Get-Date).ToString('yyyy-MM-dd')

function Fechar-Aberto($e) {
  if ($e.abertoDe) { [void]$e.fechados.Add([ordered]@{ de = $e.abertoDe; ate = $e.ultimo }); $e.abertoDe = $null }
}

function Restaurar-Estado([string]$arquivo, [string]$dia) {
  $restaurado = @{}
  if (-not (Test-Path -LiteralPath $arquivo)) { return $restaurado }
  try {
    $salvo = Get-Content -LiteralPath $arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($salvo.dia -ne $dia) { return $restaurado }
    foreach ($s in @($salvo.sites)) {
      if (-not $s.site -or $s.segundos -le 0) { continue }
      $fechados = New-Object System.Collections.ArrayList
      foreach ($seg in @($s.segmentos | Select-Object -First 240)) {
        if ($seg.de -match '^([01][0-9]|2[0-3]):[0-5][0-9]$' -and $seg.ate -match '^([01][0-9]|2[0-3]):[0-5][0-9]$' -and $seg.de -le $seg.ate) {
          [void]$fechados.Add([ordered]@{ de = $seg.de; ate = $seg.ate })
        }
      }
      $restaurado[[string]$s.site] = @{ categoria = [string]$s.categoria; segundos = [Math]::Min(86400, [int]$s.segundos); abertoDe = $null; ultimo = $null; fechados = $fechados }
    }
  } catch { return @{} }
  return $restaurado
}

function Gravar($dia) {
  $sites = @()
  foreach ($k in $estado.Keys) {
    $e = $estado[$k]
    if ($e.segundos -le 0) { continue }
    $segmentos = @($e.fechados)
    if ($e.abertoDe) { $segmentos += [ordered]@{ de = $e.abertoDe; ate = $e.ultimo } }
    $sites += [ordered]@{ site = $k; categoria = $e.categoria; segundos = [int]$e.segundos; segmentos = @($segmentos | Select-Object -First 240) }
  }
  $corpo = [ordered]@{ usuario = $env:USERNAME; dia = $dia; atualizadoEm = (Get-Date).ToUniversalTime().ToString('o'); sites = $sites }
  try {
    if (-not (Test-Path $pastaUso)) { New-Item -ItemType Directory -Force -Path $pastaUso | Out-Null }
    [System.IO.File]::WriteAllText((& $arquivoDe $dia), ($corpo | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

# Reinstalar/reiniciar durante o dia continua os totais existentes em vez de sobrescreve-los com zero.
$estado = Restaurar-Estado (& $arquivoDe $diaAtual) $diaAtual

while ($true) {
  $cfg = Ler-Sites
  $hoje = (Get-Date).ToString('yyyy-MM-dd')
  if ($hoje -ne $diaAtual) { Gravar $diaAtual; $estado = @{}; $diaAtual = $hoje }

  if (-not $cfg.ativo) {
    if ($estado.Count) { $estado = @{} }
    $arqHoje = & $arquivoDe $hoje
    if (Test-Path $arqHoje) { Remove-Item $arqHoje -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 30
    continue
  }

  $amostra = $cfg.amostraSegundos
  $ativo = $null
  if (([SvtUso]::OciosoMs() / 1000) -lt $cfg.idleSegundos) {
    $h = [SvtUso]::Frente()
    if ($h -ne [IntPtr]::Zero) {
      $procId = [SvtUso]::Pid($h)
      $titulo = [SvtUso]::Titulo($h)
      $processo = ''
      if ($procId) { $processo = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName }
      $ehNav = $NAVEGADORES -contains ($processo -replace '\.exe$', '').ToLower()
      $hostAtual = if ($ehNav) { Ler-HostDaJanela $h } else { '' }
      $ativo = Site-DaJanela $titulo $processo $hostAtual $cfg.sites
    }
  }

  $hm = (Get-Date).ToString('HH:mm')
  $nomeAtivo = if ($ativo) { $ativo.nome } else { '' }
  foreach ($k in @($estado.Keys)) { if ($k -ne $nomeAtivo) { Fechar-Aberto $estado[$k] } }
  if ($ativo) {
    if (-not $estado.ContainsKey($nomeAtivo)) {
      $estado[$nomeAtivo] = @{ categoria = $ativo.categoria; segundos = 0; abertoDe = $null; ultimo = $hm; fechados = (New-Object System.Collections.ArrayList) }
    }
    $e = $estado[$nomeAtivo]
    $e.categoria = $ativo.categoria
    $e.segundos += $amostra
    if (-not $e.abertoDe) { $e.abertoDe = $hm }
    $e.ultimo = $hm
  }

  Gravar $hoje
  Start-Sleep -Seconds $amostra
}
