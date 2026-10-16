<#
  svt-uso.ps1 - vigia, na sessao do proprio usuario, o uso do computador por item e por estado.

  So deve rodar com o aceite dos funcionarios (termo assinado). NAO le senhas, NAO le teclas digitadas,
  NAO le conversas, NAO le o conteudo das paginas, NAO guarda o link completo e NAO tira foto da tela.
  A cada poucos segundos classifica o que esta na frente:
    - item da lista (site por dominio/palavra, ou programa como Excel/Word/WhatsApp) -> guarda o nome;
    - site fora da lista -> guarda SO o dominio (ex.: exemplo.com.br), nunca o resto do link;
    - estado da sessao -> tela_bloqueada, sessao_desconectada, sem_interacao (sem mexer no mouse/teclado),
      sem_janela, area_de_trabalho, navegador_sem_dominio, programa_fora_lista, leitura_indisponivel,
      limite_dominios.
  "Teclado/mouse" entra so como ATIVIDADE (mexeu ou nao), nunca o que foi digitado.
  Grava C:\ProgramData\SVT-Monitor\uso\<usuario>-<dia>.json; o agente de sistema envia ao portal.
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
$MAX_DOMINIOS_DIA = 200

# Lista usada so se o portal ainda nao tiver mandado a dele. A de verdade vem de sites-vigiados.json.
$SITES_PADRAO = @(
  [ordered]@{ nome = 'YouTube'; categoria = 'Video'; palavras = @('youtube'); dominios = @('youtube.com'); processos = @() },
  [ordered]@{ nome = 'Instagram'; categoria = 'Rede social'; palavras = @('instagram'); dominios = @('instagram.com'); processos = @() },
  [ordered]@{ nome = 'Facebook'; categoria = 'Rede social'; palavras = @('facebook'); dominios = @('facebook.com'); processos = @() },
  [ordered]@{ nome = 'Shopee'; categoria = 'Compras'; palavras = @('shopee'); dominios = @('shopee.com.br'); processos = @() },
  [ordered]@{ nome = 'GFlex'; categoria = 'Trabalho'; palavras = @(); dominios = @('gflex.inforgeneses.com.br'); processos = @() },
  [ordered]@{ nome = 'Portal SVT'; categoria = 'Trabalho'; palavras = @(); dominios = @('portal.svtfaculdade.edu.br'); processos = @() },
  [ordered]@{ nome = 'Excel'; categoria = 'Trabalho'; palavras = @(); dominios = @(); processos = @('excel') },
  [ordered]@{ nome = 'Word'; categoria = 'Trabalho'; palavras = @(); dominios = @(); processos = @('winword') },
  [ordered]@{ nome = 'Gmail'; categoria = 'Comunicacao'; palavras = @(); dominios = @('mail.google.com'); processos = @() },
  [ordered]@{ nome = 'WhatsApp'; categoria = 'Comunicacao'; palavras = @(); dominios = @('web.whatsapp.com'); processos = @('whatsapp') }
)

# API do Windows: janela da frente, classe, processo, inatividade e bloqueio da estacao.
$SIG = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SvtUso {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode)] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
  [StructLayout(LayoutKind.Explicit)] struct SessionHeader {
    [FieldOffset(0)] public uint Level;
    [FieldOffset(8)] public uint SessionId;
    [FieldOffset(12)] public int State;
    [FieldOffset(16)] public int Flags;
  }
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  public static IntPtr Frente() { return GetForegroundWindow(); }
  public static uint Pid(IntPtr h) { uint p = 0; GetWindowThreadProcessId(h, out p); return p; }
  public static string Titulo(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
  public static string Classe(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
  public static int OciosoSegundos() {
    var li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
    if (!GetLastInputInfo(ref li)) return -1;
    return (int)(((uint)Environment.TickCount - li.dwTime) / 1000);
  }
  public static string Sessao() {
    IntPtr buffer = IntPtr.Zero; int bytes;
    try {
      if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out buffer, out bytes) || bytes < 20) return "desconhecida";
      var info = (SessionHeader)Marshal.PtrToStructure(buffer, typeof(SessionHeader));
      if (info.Level != 1) return "desconhecida";
      if (info.State != 0) return "desconectada";
      var os = Environment.OSVersion.Version;
      if (os.Major == 6 && os.Minor == 1) return "desconhecida";
      return info.Flags == 0 ? "bloqueada" : info.Flags == 1 ? "ativa" : "desconhecida";
    } catch { return "desconhecida"; }
    finally { if (buffer != IntPtr.Zero) WTSFreeMemory(buffer); }
  }
}
'@
try { if (-not ('SvtUso' -as [type])) { Add-Type -TypeDefinition $SIG -ErrorAction Stop } } catch {}

$UIA_OK = $false
try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop; $UIA_OK = $true } catch { $UIA_OK = $false }

# Extrai SO o host (dominio) de um valor da barra de endereco. Recusa arquivo local, e-mail, credencial
# na URL, busca e qualquer coisa que nao seja um dominio valido. Nunca devolve caminho, porta ou busca.
function Host-DaUrl([string]$u) {
  $u = ([string]$u).Trim()
  if (-not $u -or $u -match '\s') { return '' }
  if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    if ($u -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -and $u -notmatch '^[^/?#:\s]+:\d+([/?#]|$)') { return '' }
    $u = 'https://' + $u
  }
  $uri = $null
  if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { return '' }
  if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) { return '' }
  $dominio = $uri.IdnHost.ToLowerInvariant().TrimEnd('.')
  if (-not $dominio -or $dominio.Length -gt 253 -or $dominio.Contains('..')) { return '' }
  if ($dominio -notmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') { return '' }
  foreach ($parte in $dominio.Split('.')) { if ($parte.Length -gt 63 -or $parte.StartsWith('-') -or $parte.EndsWith('-')) { return '' } }
  return $dominio
}

# A caixa de texto do UI Automation e a barra de endereco do navegador (e nao um campo de formulario)?
function Eh-BarraDeEndereco([string]$automationId, [string]$name) {
  if ($automationId -in @('addressEditBox', 'urlbar-input', 'urlbar', 'omnibox')) { return $true }
  $nm = (([string]$name).Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').ToLowerInvariant()
  return $nm -match '^(address and search bar|address bar|search or enter (web )?address|barra de enderecos?( e (de )?pesquisa)?|pesquisar ou (inserir|digitar) endereco|search with .+ or enter address|pesquisar com .+ ou (digitar|introduzir) endereco)$'
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
        $cfg.sites = @(@($lido.sites) | Where-Object { $_.nome } | ForEach-Object {
            [ordered]@{ nome = [string]$_.nome; categoria = [string]$_.categoria; palavras = @($_.palavras); dominios = @($_.dominios); processos = @($_.processos) }
          })
      }
    } catch {}
  }
  if ($cfg.amostraSegundos -lt 5) { $cfg.amostraSegundos = 5 }
  return $cfg
}

# Casa a janela da frente com a LISTA. Devolve o item { nome; categoria; tipo='item' } ou nome vazio.
# Navegador com dominio: so por dominio. Navegador sem dominio: por palavra no titulo. Fora do
# navegador: por programa. Palavra no titulo so vale para itens sem dominio quando ha um host diferente.
function Site-DaJanela([string]$titulo, [string]$processo, [string]$hostAtual, $sites) {
  $p = ($processo -replace '\.exe$', '').ToLower()
  foreach ($s in $sites) { foreach ($proc in @($s.processos)) { if ($proc -and $p -eq (([string]$proc) -replace '\.exe$', '').ToLower()) { return @{ nome = $s.nome; categoria = $s.categoria; tipo = 'item' } } } }
  $ehNav = $NAVEGADORES -contains $p
  if ($ehNav -and $hostAtual) {
    foreach ($s in $sites) {
      foreach ($d in @($s.dominios)) {
        $dom = ([string]$d).ToLower().TrimStart('.')
        if ($dom -and ($hostAtual -eq $dom -or $hostAtual.EndsWith('.' + $dom))) { return @{ nome = $s.nome; categoria = $s.categoria; tipo = 'item' } }
      }
    }
  }
  if ($ehNav) {
    $t = ([string]$titulo).ToLower()
    foreach ($s in $sites) {
      if ($hostAtual -and @($s.dominios | Where-Object { $_ }).Count) { continue }
      foreach ($palavra in @($s.palavras)) { if ($palavra -and $t.Contains(([string]$palavra).ToLower())) { return @{ nome = $s.nome; categoria = $s.categoria; tipo = 'item' } } }
    }
  }
  return @{ nome = ''; categoria = ''; tipo = '' }
}

function Estado-DeUso([string]$codigo) { return @{ nome = $codigo; categoria = 'Estado'; tipo = 'estado' } }

# Classifica uma observacao (ja coletada) em um alvo. Puro: nao toca na tela nem no sistema.
# $obs: sessao (ativa|bloqueada|desconectada), ociosoSegundos (ou $null), temJanela, classe, processo,
# dominio (valor cru da barra de endereco), titulo.
function Classificar-Uso($obs, $cfg) {
  if ($obs.sessao -eq 'bloqueada') { return Estado-DeUso 'tela_bloqueada' }
  if ($obs.sessao -eq 'desconectada') { return Estado-DeUso 'sessao_desconectada' }
  if ($null -eq $obs.ociosoSegundos) { return Estado-DeUso 'leitura_indisponivel' }
  if ([double]$obs.ociosoSegundos -ge [double]$cfg.idleSegundos) { return Estado-DeUso 'sem_interacao' }
  if (-not $obs.temJanela) { return Estado-DeUso 'sem_janela' }
  $p = ($obs.processo -replace '\.exe$', '').ToLower()
  if ($p -eq 'explorer' -and ($obs.classe -eq 'Progman' -or $obs.classe -eq 'WorkerW')) { return Estado-DeUso 'area_de_trabalho' }
  $hostAtual = Host-DaUrl $obs.dominio
  $item = Site-DaJanela $obs.titulo $obs.processo $hostAtual $cfg.sites
  if ($item.nome) { return @{ nome = $item.nome; categoria = $item.categoria; tipo = 'item' } }
  if ($NAVEGADORES -contains $p) {
    if ($hostAtual) { return @{ nome = $hostAtual; categoria = 'Fora da lista'; tipo = 'dominio' } }
    return Estado-DeUso 'navegador_sem_dominio'
  }
  if (-not $p) { return Estado-DeUso 'leitura_indisponivel' }
  return Estado-DeUso 'programa_fora_lista'
}

function Fechar-Aberto($e) {
  if ($e.abertoDe) { [void]$e.fechados.Add([ordered]@{ de = $e.abertoDe; ate = $e.ultimo }); $e.abertoDe = $null }
}

# Acrescenta uma amostra ao $estado. Fecha o trecho em aberto de outros alvos; nao junta trechos com
# intervalo maior que a amostra; e nao deixa um trecho atravessar a meia-noite.
function Registrar-Amostra($alvo, [datetime]$quando, [int]$segundos) {
  $chave = if (-not $alvo.tipo -or $alvo.tipo -eq 'item') { [string]$alvo.nome } else { "$($alvo.tipo):$($alvo.nome)" }
  foreach ($k in @($estado.Keys)) { if ($k -ne $chave) { Fechar-Aberto $estado[$k] } }
  if (-not $estado.ContainsKey($chave)) {
    $estado[$chave] = @{ nome = $alvo.nome; categoria = $alvo.categoria; tipo = (&{ if ($alvo.tipo) { $alvo.tipo } else { 'item' } }); segundos = 0; abertoDe = $null; ultimo = $null; fechados = (New-Object System.Collections.ArrayList) }
  }
  $e = $estado[$chave]
  $e.categoria = $alvo.categoria
  $fimDia = $quando.Date.AddDays(1).AddSeconds(-1)
  $fim = $quando.AddSeconds($segundos); if ($fim -gt $fimDia) { $fim = $fimDia }
  $e.segundos += [Math]::Max(0, [int]($fim - $quando).TotalSeconds)
  $de = $quando.ToString('HH:mm:ss'); $ate = $fim.ToString('HH:mm:ss')
  if ($e.abertoDe) {
    $ultimoFim = [datetime]::ParseExact(($quando.ToString('yyyy-MM-dd') + ' ' + $e.ultimo), 'yyyy-MM-dd HH:mm:ss', $null)
    if (($quando - $ultimoFim).TotalSeconds -le 5) { $e.ultimo = $ate }
    else { Fechar-Aberto $e; $e.abertoDe = $de; $e.ultimo = $ate }
  }
  else { $e.abertoDe = $de; $e.ultimo = $ate }
}

# Reconstroi o $estado a partir do arquivo do dia (sobrevive a atualizacao do agente no meio do dia).
function Restaurar-Estado($arquivo, $dia) {
  $e = @{}
  if (-not (Test-Path $arquivo)) { return $e }
  $d = $null
  try { $d = Get-Content $arquivo -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $e }
  if (-not $d -or [string]$d.dia -ne $dia) { return $e }
  foreach ($s in @($d.sites)) {
    if (-not $s.site) { continue }
    $tipo = if ($s.tipo) { [string]$s.tipo } else { 'item' }
    $fechados = New-Object System.Collections.ArrayList
    foreach ($seg in @($s.segmentos)) { if ($seg.de -and $seg.ate) { [void]$fechados.Add([ordered]@{ de = [string]$seg.de; ate = [string]$seg.ate }) } }
    $chave = if ($tipo -eq 'item') { [string]$s.site } else { "$($tipo):$($s.site)" }
    $e[$chave] = @{ nome = [string]$s.site; categoria = [string]$s.categoria; tipo = $tipo; segundos = [int]$s.segundos; abertoDe = $null; ultimo = $null; fechados = $fechados }
  }
  return $e
}

# Grava o arquivo do dia. So dados agregados: site/dominio/estado, categoria, segundos e horarios.
# Nunca URL, titulo, nome de documento ou conteudo. "tipo" so aparece para dominio e estado.
function Gravar($dia) {
  $sites = @()
  foreach ($chave in $estado.Keys) {
    $e = $estado[$chave]
    if ($e.segundos -le 0) { continue }
    $segmentos = @($e.fechados)
    if ($e.abertoDe) { $segmentos += [ordered]@{ de = $e.abertoDe; ate = $e.ultimo } }
    $entrada = [ordered]@{ site = $e.nome }
    if ($e.tipo -and $e.tipo -ne 'item') { $entrada.tipo = $e.tipo }
    $entrada.categoria = $e.categoria
    $entrada.segundos = [int]$e.segundos
    $entrada.segmentos = @($segmentos | Select-Object -First 240)
    $sites += $entrada
  }
  $corpo = [ordered]@{ usuario = $env:USERNAME; dia = $dia; atualizadoEm = (Get-Date).ToUniversalTime().ToString('o'); sites = $sites }
  try {
    if (-not (Test-Path $pastaUso)) { New-Item -ItemType Directory -Force -Path $pastaUso | Out-Null }
    [System.IO.File]::WriteAllText((& $arquivoDe $dia), ($corpo | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

# Le somente o host da barra de endereco; nunca percorre o documento da pagina.
function Ler-UrlDaJanela($h) {
  if (-not $UIA_OK) { return '' }
  try {
    $raiz = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    if (-not $raiz) { return '' }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $fila = New-Object System.Collections.Queue
    $fila.Enqueue($raiz)
    $vistos = 0
    while ($fila.Count -and $vistos -lt 400) {
      $e = $fila.Dequeue(); $vistos++
      $info = $e.Current
      if ($info.ControlType -eq [System.Windows.Automation.ControlType]::Document) { continue }
      if ($info.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and (Eh-BarraDeEndereco $info.AutomationId $info.Name)) {
        if ($info.HasKeyboardFocus) { return '' }
        $vp = $null
        if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { return (Host-DaUrl $vp.Current.Value) }
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

# Monta a observacao do momento a partir das APIs reais (so aqui le tela/sessao).
function Observar($cfg) {
  $obs = @{ sessao = [SvtUso]::Sessao(); ociosoSegundos = $null; temJanela = $false; classe = ''; processo = ''; dominio = ''; titulo = '' }
  $o = [SvtUso]::OciosoSegundos(); if ($o -ge 0) { $obs.ociosoSegundos = $o }
  if ($obs.sessao -in @('bloqueada', 'desconectada') -or $null -eq $obs.ociosoSegundos -or $obs.ociosoSegundos -ge $cfg.idleSegundos) { return $obs }
  $h = [SvtUso]::Frente()
  if ($h -ne [IntPtr]::Zero) {
    $obs.temJanela = $true
    $obs.classe = [SvtUso]::Classe($h)
    $procId = [SvtUso]::Pid($h)
    if ($procId) { $obs.processo = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName }
    if ($NAVEGADORES -contains ([string]$obs.processo -replace '\.exe$', '').ToLower()) {
      $obs.dominio = Ler-UrlDaJanela $h
      $obs.titulo = [SvtUso]::Titulo($h)
    }
  }
  return $obs
}

# Modo teste: classifica valores dados (nao le a tela, nao grava) e sai.
if ($TesteTitulo -or $TesteProcesso -or $TesteUrl) {
  $a = Site-DaJanela $TesteTitulo $TesteProcesso (Host-DaUrl $TesteUrl) (Ler-Sites).sites
  if ($a.nome) { Write-Output ("ITEM: {0} [{1}]" -f $a.nome, $a.categoria) } else { Write-Output 'ITEM: (nenhum da lista)' }
  exit 0
}

# ---------------------------------------------------------------- laco principal
$pastaUso = Join-Path $Pasta 'uso'
$usuario = ($env:USERNAME -replace '[^A-Za-z0-9._-]', '_')
if (-not $usuario) { $usuario = 'usuario' }
$arquivoDe = { param($dia) Join-Path $pastaUso ("{0}-{1}.json" -f $usuario, $dia) }

$diaAtual = (Get-Date).ToString('yyyy-MM-dd')
$estado = Restaurar-Estado (& $arquivoDe $diaAtual) $diaAtual
$dominiosVistos = @{}
foreach ($e in $estado.Values) { if ($e.tipo -eq 'dominio') { $dominiosVistos[$e.nome] = $true } }

while ($true) {
  $cfg = Ler-Sites
  $hoje = (Get-Date).ToString('yyyy-MM-dd')
  if ($hoje -ne $diaAtual) { Gravar $diaAtual; $estado = @{}; $dominiosVistos = @{}; $diaAtual = $hoje }

  if (-not $cfg.ativo) {
    if ($estado.Count) { $estado = @{} }
    $arqHoje = & $arquivoDe $hoje
    if (Test-Path $arqHoje) { Remove-Item $arqHoje -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 30
    continue
  }

  $amostra = $cfg.amostraSegundos
  try { $alvo = Classificar-Uso (Observar $cfg) $cfg } catch { $alvo = Estado-DeUso 'leitura_indisponivel' }
  if ($alvo.tipo -eq 'dominio') {
    if (-not $dominiosVistos.ContainsKey($alvo.nome)) {
      if ($dominiosVistos.Count -ge $MAX_DOMINIOS_DIA) { $alvo = Estado-DeUso 'limite_dominios' }
      else { $dominiosVistos[$alvo.nome] = $true }
    }
  }
  $instante = Get-Date
  $diaDaAmostra = $instante.ToString('yyyy-MM-dd')
  if ($diaDaAmostra -ne $diaAtual) { Gravar $diaAtual; $estado = @{}; $dominiosVistos = @{}; $diaAtual = $diaDaAmostra }
  Registrar-Amostra $alvo $instante $amostra
  Gravar $diaAtual
  Start-Sleep -Seconds $amostra
}
