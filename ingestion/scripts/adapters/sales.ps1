#Requires -Version 7.4
<#
.SYNOPSIS
  Reads auctions and estate sales, for the Auctions and Estate Sales category.
.DESCRIPTION
  One request a night per source (plus robots.txt), checked against robots.txt and spaced by its
  Crawl-delay. No link on the page is followed. It applies these rules (lib/Sales.ps1):

  - In-person only. Anything whose title or text says "online", and anything with no street
    address or place, is dropped (the in-person rule).
  - No real estate: auctions of a house or land are dropped (the feed's Real Estate category, or
    "real estate" in a title), unless the source sets
    keepRealEstate for live real estate auctions held at the property.
  - Only the cities the site already covers are kept (the city filter).
  - Only the title, the company (as the venue), the city, start and end, and the link to the
    event on the company's site are stored. No address, photos, description, contact details,
    or price.

  How many events each rule dropped is written with Write-Verbose.

  salesMode:
  - ics: an Events Calendar iCal export from an auction company. The start time comes from the description
    ("at 2 pm"), since the feed gives dates only. Its real estate auctions are titled by street
    address, and are dropped by the real estate rule unless the source sets keepRealEstate.
.PARAMETER Source
  One entry from sources.json.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  The feed or page to parse instead of fetching. Used by tests.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][pscustomobject]$Source,
  [Parameter(Mandatory)][string]$FetchedAt,
  [string[]]$Response
)

. "$PSScriptRoot/../lib/Schema.ps1"
. "$PSScriptRoot/../lib/Http.ps1"
. "$PSScriptRoot/../lib/Scrape.ps1"
. "$PSScriptRoot/../lib/Ics.ps1"
. "$PSScriptRoot/../lib/Sales.ps1"

$today = [datetime]::ParseExact((ConvertTo-BoulderTime $FetchedAt).Substring(0, 10), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$clock = '\d{1,2}(?::\d{2})?\s*[AaPp]\.?\s*[Mm]\b\.?'
$dropped = @{ 'in-person' = 0; 'real-estate' = 0; city = 0 }
$kept = 0

function Get-SalesText {
  # The source's page, after checking robots.txt and waiting out its Crawl-delay.
  if ($Response) { return $Response[0] }

  $uri = [uri]$Source.url
  $robots = try { Invoke-WbRequest "$($uri.GetLeftPart('Authority'))/robots.txt" -Raw } catch {
    # No robots.txt means no restrictions. Any other failure means we can't tell, so stop.
    if ("$_" -match 'HTTP 404') { '' } else { throw }
  }
  if (-not (Test-WbRobotsAllowed $robots $uri.PathAndQuery)) { throw "$($Source.name): robots.txt disallows $($uri.PathAndQuery)" }
  $delay = [Math]::Max(1, [int](Get-WbRobotsGroup $robots).Delay)
  if ($delay -gt 60) { throw "$($Source.name): robots.txt asks for $delay seconds between requests" }
  Start-Sleep -Seconds $delay
  Invoke-WbRequest $uri.AbsoluteUri -Raw
}

function Add-Sale {
  # Applies the in-person rule, the real estate rule, and the city filter, then emits the event or
  # counts the drop.
  param([string]$Title, [string]$Text, [string]$Town, [hashtable]$Event, [switch]$RealEstate)

  $city = if ($Town) { Resolve-WbCity $Town }
  $verdict = Get-WbSaleVerdict -Title $Title -Text $Text -HasPlace ([bool]$Town) -City $city -RealEstate ([bool]$RealEstate -and -not $Source.keepRealEstate)
  if ($verdict -ne 'keep') {
    $script:dropped[$verdict]++
    $why = switch ($verdict) { 'city' { "the city filter ($Town)" } 'real-estate' { 'the real estate rule' } default { 'the in-person rule' } }
    Write-Verbose "$($Source.name): '$Title' dropped by $why"
    return
  }
  try {
    New-WbSaleEvent -Source $Source -FetchedAt $FetchedAt -City $city @Event
    $script:kept++
  } catch {
    Write-Warning "$($Source.name): skipping '$Title': $_"
  }
}

function Read-IcsSales {
  param([string]$Text)

  if ($Text -notmatch 'BEGIN:VCALENDAR') { throw "$($Source.name): response is not an iCalendar feed" }
  foreach ($item in (ConvertFrom-Ics $Text)) {
    if ($item.Status -eq 'CANCELLED') { continue }
    $title = ConvertTo-PlainText $item.Summary
    $lines = @($item.Description -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $locationLine = ($lines | Where-Object { $_ -match '^LOCATION:\s*(.+)$' } | Select-Object -First 1) -replace '^LOCATION:\s*', ''
    $town = Find-WbSaleTown (@($item.Location, $locationLine, $title, $lines[0]) -join "`n")

    $event = @{ Url = if ($item.Url) { $item.Url } else { $Source.url } }
    $at = [regex]::Match($item.Description, "(?i)\bat\s+(?<t>$clock)")
    $start = if ($item.AllDay -and $at.Success) { ConvertTo-WbSaleTime $item.Start $at.Groups['t'].Value }
    if ($start) {
      $event.Start = $start
    } else {
      $event.Start = $item.Start
      if ($item.End) { $event.End = $item.End }
      $event.AllDay = [bool]$item.AllDay
    }

    # A title that is a street address is a real estate listing, which the real estate rule drops.
    $event.Title = $title
    Add-Sale -Title $title -Text "$($item.Description)`n$($item.Categories)" -Town $town -Event $event `
      -RealEstate:($item.Categories -match '(?i)\breal estate\b' -or $title -match '^\d+\s+\S')
  }
}

$text = Get-SalesText
switch ($Source.salesMode) {
  'ics' { Read-IcsSales $text }
  default { throw "$($Source.name): unknown salesMode '$($Source.salesMode)'" }
}
Write-Verbose "$($Source.name): kept $kept, $($dropped['in-person']) dropped by the in-person rule, $($dropped['real-estate']) dropped as real estate, $($dropped.city) dropped by the city filter"
