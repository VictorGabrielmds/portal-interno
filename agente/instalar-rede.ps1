<#
  Instala/atualiza somente inventario, seguranca e rede. Nao instala a vigia.
  Em um PC que ja tinha coleta de uso, desativa essa coleta e mantem o monitor tecnico.
  O token e o comando pronto ficam em Infraestrutura > Instalar agente.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Token,
  [string]$Url = 'https://us-central1-portal-interno-svt.cloudfunctions.net/receberTelemetria',
  [switch]$Coletor,
  [string[]]$Redes = @(),
  [string]$Comunidade = 'public',
  [string]$Origem = 'https://portal.svtfaculdade.edu.br/agente'
)
$ErrorActionPreference = 'Stop'
$instalador = Join-Path $env:TEMP ('svt-inventario-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "$Origem/instalar.ps1" -OutFile $instalador -UseBasicParsing
  & $instalador -Token $Token -Url $Url -Coletor:$Coletor -Redes $Redes -Comunidade $Comunidade -Origem $Origem -SemUso
} finally {
  Remove-Item -LiteralPath $instalador -Force -ErrorAction SilentlyContinue
}
