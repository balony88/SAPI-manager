<#
.SYNOPSIS
  Testovaci klient rozhrania SAPI-SK.

.DESCRIPTION
  Klient je navrhnuty na pouzitie s pristupovymi bodmi podporujucimi SAPI-SK
  podla https://www.sapi-sk.sk/. Kompatibilita so vsetkymi poskytovatelmi
  nebola overena a zavisi od ich implementacie.

  Konfiguracia je v .env.sapi vedla skriptu (alebo v subore -ConfigPath).
  Vytvorte SAPI klienta na portali a doplnte APP_BASE_URL, CLIENT_ID a CLIENT_SECRET.
  Na pracu s dokumentmi doplnte aj PEPPOL_PARTICIPANT_ID alebo -ParticipantId.
  Subor obsahuje secret: nezdielajte ho a neukladajte do Gitu.

  Bez parametrov sa iba overi vydanie a platnost tokenu. Token sa nikdy nevypisuje.

  Priklady:
    .\SAPI-manager.ps1 -TestConnect
    .\SAPI-manager.ps1 -Pull
    .\SAPI-manager.ps1 -Pull -Limit 10 -PageToken '<token-stranky>'
    .\SAPI-manager.ps1 -Download -DocumentId '<id>' -OutputPath .\doklad.xml
    .\SAPI-manager.ps1 -Acknowledge -DocumentId '<id>'
    .\SAPI-manager.ps1 -Send -XmlPath .\doklad.xml -MetadataPath .\metadata.json -IdempotencyKey '<uuid>'

  -Pull vypise metadáta jednej strany; dalsiu stranu zadajte cez -PageToken.
  -Download nezapisuje ACK a neprepisuje existujuci subor.
  -Acknowledge zaznamena technicke prevzatie; nie je to schvalenie ani uhrada.
  -Send skutocne prijme dokument na odoslanie cez Peppol a moze vytvorit realny doklad.
  MetadataPath obsahuje JSON objekt SAPI metadata (documentId, documentTypeId, processId,
  senderParticipantId, receiverParticipantId, creationDateTime). Pred odoslanim overte
  spravnost metadat a platnost UBL XML. Vzor pre fakturu je metadata.example.json;
  hodnoty upravte podla realneho dokladu a pouziteho profilu.
  Odpoved ACCEPTED je len technicke prijatie.
  Pri opakovani pouzite rovnaky IdempotencyKey, rovnake metadáta aj XML; nepouzivajte
  novy kluc pri neistom vysledku. Skript odoslanie automaticky neopakuje.

  APP_BASE_URL je origin portalu, napr. https://dev.e-fakturuj.sk; podporuje aj koncove /sapi.
  HTTPS je povinne okrem localhost alebo loopback adresy. Presmerovania sa nenasleduju.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath,
  [switch]$TestConnect,
  [switch]$Pull,
  [switch]$Download,
  [switch]$Acknowledge,
  [switch]$Send,
  [string]$ParticipantId,
  [string]$DocumentId,
  [string]$OutputPath,
  [string]$XmlPath,
  [string]$MetadataPath,
  [string]$IdempotencyKey,
  [ValidateRange(1, 100)][int]$Limit = 20,
  [string]$PageToken,
  [ValidateSet('RECEIVED', 'ACKNOWLEDGED')][string]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot '.env.sapi' }

function Read-SapiConfig([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw 'Konfiguracny subor neexistuje. Skopirujte .env.sapi.example do .env.sapi.'
  }
  $values = @{}
  foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*(#.*)?$') { continue }
    if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
      throw 'Neplatny riadok v konfiguracnom subore.'
    }
    $name = $Matches[1]
    $value = $Matches[2]
    if ($values.ContainsKey($name)) { throw "Duplicitna konfiguracna polozka: $name." }
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or
        ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $values[$name] = $value
  }
  foreach ($name in @('APP_BASE_URL', 'CLIENT_ID', 'CLIENT_SECRET')) {
    if (-not $values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($values[$name])) {
      throw "V konfiguracii chyba $name."
    }
  }
  return $values
}

function Get-SapiBaseUrl([string]$Value) {
  $uri = $null
  if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri) -or
      $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
      $uri.AbsolutePath.TrimEnd('/') -notin @('', '/sapi')) {
    throw 'APP_BASE_URL musi byt URL portalu alebo URL konciaca na /sapi, bez prihlasovacich udajov, query a fragmentu.'
  }
  $ip = $null
  $loopback = $uri.Host -eq 'localhost' -or
    ([System.Net.IPAddress]::TryParse($uri.Host.Trim('[', ']'), [ref]$ip) -and [System.Net.IPAddress]::IsLoopback($ip))
  if ($uri.Scheme -ne 'https' -and -not $loopback) {
    throw 'Pre vzdialeny server je povinne HTTPS.'
  }
  return $uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/') + '/sapi'
}

function Invoke-SapiRequest {
  param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
  Add-Type -AssemblyName System.Net.Http
  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $client = [System.Net.Http.HttpClient]::new($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(60)
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
  try {
    foreach ($name in $Headers.Keys) {
      if (-not $request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name])) {
        throw 'SAPI hlavicku sa nepodarilo nastavit.'
      }
    }
    if ($null -ne $Body) {
      $json = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
      $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    }
    try {
      $response = $client.SendAsync($request).GetAwaiter().GetResult()
    } catch {
      throw 'SAPI poziadavka zlyhala. Overte adresu, siet a TLS spojenie.'
    }
    try {
      if (-not $response.IsSuccessStatusCode) {
        $statusCode = [int]$response.StatusCode
        throw "SAPI poziadavka zlyhala (HTTP $statusCode). Overte logy SAPI a konfiguraciu."
      }
      $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      try { return $content | ConvertFrom-Json } catch { throw 'SAPI vratilo neplatnu JSON odpoved.' }
    } finally { $response.Dispose() }
  } finally {
    $request.Dispose()
    $client.Dispose()
  }
}

function Assert-DocumentId([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @('.', '..') -or $Value -match '[/\\%]') {
    throw 'Zadajte platne -DocumentId bez lomky, percenta a samostatnych bodiek.'
  }
}

try {
  $operations = @(@($TestConnect, $Pull, $Download, $Acknowledge, $Send) | Where-Object { $_ })
  if ($operations.Count -gt 1) { throw 'Zvolte iba jednu operaciu.' }
  if (($Download -or $Acknowledge)) { Assert-DocumentId $DocumentId }
  if ($Download -and [string]::IsNullOrWhiteSpace($OutputPath)) { throw 'Pre -Download zadajte -OutputPath.' }
  if ($Send) {
    if ([string]::IsNullOrWhiteSpace($XmlPath) -or [string]::IsNullOrWhiteSpace($MetadataPath)) {
      throw 'Pre -Send zadajte -XmlPath a -MetadataPath.'
    }
    $parsedKey = [guid]::Empty
    if (-not [guid]::TryParse($IdempotencyKey, [ref]$parsedKey) -or
        $IdempotencyKey -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') {
      throw 'Pre -Send zadajte platny UUID -IdempotencyKey; pri opakovani pouzite rovnaky kluc.'
    }
    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf) -or -not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
      throw 'XML alebo subor metadat neexistuje.'
    }
    try {
      $metadata = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $MetadataPath).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { throw 'Subor metadat neobsahuje platny JSON.' }
    foreach ($field in @('documentId', 'documentTypeId', 'processId', 'senderParticipantId', 'receiverParticipantId', 'creationDateTime')) {
      if (-not $metadata.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$metadata.$field)) {
        throw "V metadata JSON chyba $field."
      }
    }
    $payload = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $XmlPath).Path, [System.Text.Encoding]::UTF8)
  }
  if ($Download -and (Test-Path -LiteralPath $OutputPath)) {
    throw 'Vystupny subor uz existuje; skript ho neprepise.'
  }

  $config = Read-SapiConfig $ConfigPath
  $base = Get-SapiBaseUrl $config.APP_BASE_URL
  if ([string]::IsNullOrWhiteSpace($ParticipantId) -and $config.ContainsKey('PEPPOL_PARTICIPANT_ID')) {
    $ParticipantId = $config.PEPPOL_PARTICIPANT_ID
  }
  if (($Pull -or $Download -or $Acknowledge -or $Send) -and [string]::IsNullOrWhiteSpace($ParticipantId)) {
    throw 'Pre pracu s dokumentmi zadajte PEPPOL_PARTICIPANT_ID alebo -ParticipantId.'
  }
  if ($Send -and $metadata.senderParticipantId -ne $ParticipantId) {
    throw 'senderParticipantId v metadata JSON sa nezhoduje s Peppol ID firmy.'
  }

  $token = Invoke-SapiRequest -Method POST -Url "$base/auth/token" -Body @{
    grant_type = 'client_credentials'
    client_id = $config.CLIENT_ID
    client_secret = $config.CLIENT_SECRET
  }
  if (-not $token -or -not $token.PSObject.Properties['access_token'] -or
      [string]::IsNullOrWhiteSpace([string]$token.access_token)) {
    throw 'SAPI nevratilo platny access token.'
  }
  $headers = @{ Authorization = "Bearer $($token.access_token)" }
  if ($ParticipantId) { $headers['X-Peppol-Participant-Id'] = $ParticipantId }

  if ($Pull) {
    $url = "$base/document/receive?limit=$Limit"
    if ($PageToken) { $url += '&pageToken=' + [Uri]::EscapeDataString($PageToken) }
    if ($Status) { $url += '&status=' + [Uri]::EscapeDataString($Status) }
    $result = Invoke-SapiRequest -Method GET -Url $url -Headers $headers
    if (-not $result -or -not $result.PSObject.Properties['documents'] -or $result.documents -isnot [array]) {
      throw 'SAPI vratilo neplatny zoznam dokumentov.'
    }
    $result | ConvertTo-Json -Depth 30
  } elseif ($Download) {
    $id = [Uri]::EscapeDataString($DocumentId)
    $result = Invoke-SapiRequest -Method GET -Url "$base/document/receive/$id" -Headers $headers
    if (-not $result -or -not $result.PSObject.Properties['payload'] -or
        -not $result.PSObject.Properties['payloadFormat'] -or $result.payloadFormat -ne 'XML' -or
        [string]::IsNullOrWhiteSpace([string]$result.payload)) {
      throw 'SAPI nevratilo XML dokument.'
    }
    $resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location).Path $OutputPath }
    $fullPath = [System.IO.Path]::GetFullPath($resolvedOutput)
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$result.payload)
      $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Write-Output "XML ulozene: $fullPath"
  } elseif ($Acknowledge) {
    $id = [Uri]::EscapeDataString($DocumentId)
    $result = Invoke-SapiRequest -Method POST -Url "$base/document/receive/$id/acknowledge" -Headers $headers
    if (-not $result -or -not $result.PSObject.Properties['status'] -or $result.status -ne 'ACKNOWLEDGED') {
      throw 'SAPI nepotvrdilo technicke prevzatie dokumentu.'
    }
    $result | ConvertTo-Json -Depth 30
  } elseif ($Send) {
    $headers['Idempotency-Key'] = $IdempotencyKey
    Write-Output "Odosielanie dokumentu s Idempotency-Key: $IdempotencyKey"
    $result = Invoke-SapiRequest -Method POST -Url "$base/document/send" -Headers $headers -Body @{
      metadata = $metadata
      payload = $payload
      payloadFormat = 'XML'
      payloadEncoding = 'UTF-8'
    }
    if (-not $result -or -not $result.PSObject.Properties['status'] -or $result.status -ne 'ACCEPTED') {
      throw 'SAPI nepotvrdilo technicke prijatie dokumentu. Pred opakovanim overte stav a pouzite rovnaky idempotentny kluc.'
    }
    $result | ConvertTo-Json -Depth 30
    Write-Output 'ACCEPTED znamena technicke prijatie, nie potvrdenie dorucenia.'
  } else {
    $result = Invoke-SapiRequest -Method GET -Url "$base/auth/token/status" -Headers $headers
    if (-not $result -or -not $result.PSObject.Properties['valid'] -or $result.valid -ne $true) {
      throw 'SAPI nepotvrdilo platnost tokenu.'
    }
    Write-Output 'SAPI pripojenie a platnost tokenu boli overene.'
  }
} catch {
  Write-Error -ErrorAction Continue $_.Exception.Message
  exit 1
}
