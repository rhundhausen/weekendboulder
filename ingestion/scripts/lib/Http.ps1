# HTTP and JSON helpers. Every outbound request goes through Invoke-WbRequest.

function Get-WbUserAgent {
  'WeekendBoulder/1.0 (+https://github.com/rhundhausen/weekendboulder)'
}

function Hide-WbSecret {
  # Credentials travel in query strings, so strip them before a URL reaches a log.
  param([string]$Text)

  $Text -replace '(?i)\b(apikey|app_id|client_id|client_secret|token|key)=[^&\s"'']+', '$1=***'
}

function ConvertFrom-WbJsonElement {
  param([System.Text.Json.JsonElement]$Element)

  switch ($Element.ValueKind.ToString()) {
    'Object' {
      $properties = [ordered]@{}
      foreach ($property in $Element.EnumerateObject()) {
        $properties[$property.Name] = ConvertFrom-WbJsonElement $property.Value
      }
      return [pscustomobject]$properties
    }
    'Array' {
      $items = foreach ($item in $Element.EnumerateArray()) { , (ConvertFrom-WbJsonElement $item) }
      return , @($items)
    }
    'String' { return $Element.GetString() }
    'Number' { return $Element.GetDouble() }
    'True' { return $true }
    'False' { return $false }
    default { return $null }
  }
}

function ConvertFrom-WbJson {
  <#
  .SYNOPSIS
    Parses JSON and leaves every string a string.
  .DESCRIPTION
    ConvertFrom-Json turns ISO 8601 strings into DateTime values in the machine's zone, which
    would corrupt stored start times. -DateKind String only exists from PowerShell 7.5.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$Json
  )

  process {
    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
      $result = ConvertFrom-WbJsonElement $document.RootElement
    } finally {
      $document.Dispose()
    }
    $result
  }
}

function Invoke-WbRequest {
  <#
  .SYNOPSIS
    GETs a URL with the project User-Agent, a timeout, and one retry on 5xx. -Method Post with a
    -Form hashtable sends a form POST instead, for WordPress admin-ajax calendars.
  .PARAMETER Raw
    Return the response body as text, for ICS feeds. Otherwise the body is parsed as JSON.
  .PARAMETER Headers
    Extra request headers, such as Authorization. They are never logged.
  .PARAMETER RetryDelaySeconds
    Pause before the retry.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Uri,

    [switch]$Raw,

    [hashtable]$Headers = @{},

    [ValidateSet('Get', 'Post')][string]$Method = 'Get',

    [hashtable]$Form,

    [int]$TimeoutSec = 30,

    [int]$RetryDelaySeconds = 5
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      $request = @{ Uri = $Uri; UserAgent = (Get-WbUserAgent); Headers = $Headers; TimeoutSec = $TimeoutSec; Method = $Method }
      if ($Form) { $request.Body = $Form }
      $response = Invoke-WebRequest @request -SkipHttpErrorCheck -ErrorAction Stop
    } catch {
      throw "Request failed for $(Hide-WbSecret $Uri): $(Hide-WbSecret $_.Exception.Message)"
    }

    $status = [int]$response.StatusCode
    if ($status -ge 500 -and $attempt -eq 1) {
      Write-Warning "HTTP $status from $(Hide-WbSecret $Uri), retrying once"
      Start-Sleep -Seconds $RetryDelaySeconds
      continue
    }
    if ($status -lt 200 -or $status -ge 300) {
      throw "HTTP $status from $(Hide-WbSecret $Uri)"
    }

    # Decode the bytes ourselves. text/calendar with no charset would otherwise be read as Latin-1.
    $body = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    if ($Raw) { return $body }
    return ConvertFrom-WbJson $body
  }
}
