# Fills in the city for events stored as Other, from clues in their own text.

. "$PSScriptRoot/Schema.ps1"

# Colorado ZIP codes for the cities in the schema. 80027 is left out on purpose: Louisville and
# Superior share it, so other clues decide. 80503 is Longmont's and Niwot's; it maps to Longmont.
# Gunbarrel (80301) has Boulder addresses.
$script:WbZipCities = @{
  '80301' = 'Boulder'; '80302' = 'Boulder'; '80303' = 'Boulder'; '80304' = 'Boulder'
  '80305' = 'Boulder'; '80306' = 'Boulder'; '80307' = 'Boulder'; '80308' = 'Boulder'
  '80309' = 'Boulder'; '80310' = 'Boulder'; '80314' = 'Boulder'
  '80501' = 'Longmont'; '80502' = 'Longmont'; '80503' = 'Longmont'; '80504' = 'Longmont'
  '80026' = 'Lafayette'
  '80516' = 'Erie'
  '80020' = 'Broomfield'; '80023' = 'Broomfield'
  '80544' = 'Niwot'
  '80540' = 'Lyons'
  '80466' = 'Nederland'
}

# Cities whose names are also everyday words or surnames ("superior sound", "Lake Erie", "Lyons
# Brothers"). These are trusted only from a ZIP code or a "City, CO" pattern, never from a bare word.
$script:WbAmbiguousCities = @('Superior', 'Erie', 'Lyons')

function Get-WbCityNames {
  # Every city in the event schema except Other, longest first so "Broomfield" is tried before shorter names.
  $schema = Join-Path $PSScriptRoot '..' '..' 'schema' 'event.schema.json'
  if (-not $script:WbCityNames) {
    $enum = (Get-Content -LiteralPath $schema -Raw | ConvertFrom-Json).properties.city.enum
    $script:WbCityNames = @($enum | Where-Object { $_ -ne 'Other' } | Sort-Object Length -Descending)
  }
  $script:WbCityNames
}

function Get-WbPlaceCities {
  # data/schema/place-cities.json, loaded once.
  if (-not $script:WbPlaceCities) {
    $path = Join-Path $PSScriptRoot '..' '..' '..' 'data' 'schema' 'place-cities.json'
    $script:WbPlaceCities = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
  }
  $script:WbPlaceCities
}

function Remove-WbNonPlace {
  # Blanks out names that contain a city but aren't places in it, such as Boulder County.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$Text)

  foreach ($name in @((Get-WbPlaceCities).ignore)) {
    $Text = $Text -replace ('(?i)\b' + [regex]::Escape($name) + '\b'), ' '
  }
  $Text
}

function Find-WbPlace {
  # Cities of the known places named in the text.
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Text)

  $places = (Get-WbPlaceCities).places
  @($places.Keys | Where-Object { $Text -match ('(?i)\b' + [regex]::Escape($_) + '(?!\w)') } | ForEach-Object { $places[$_] } | Select-Object -Unique)
}

function Find-WbCityWord {
  # Distinct cities named as whole words in the text, optionally only when followed by ", CO" or ", Colorado".
  [CmdletBinding()]
  param(
    [AllowEmptyString()][string]$Text,
    [switch]$WithState,
    [switch]$Unambiguous,
    [string]$Before = ''
  )

  if (-not $Text) { return @() }
  $found = [Collections.Generic.List[string]]::new()
  foreach ($city in (Get-WbCityNames)) {
    if ($Unambiguous -and $city -in $script:WbAmbiguousCities) { continue }
    $pattern = '(?i)' + $Before + '\b' + [regex]::Escape($city) + '\b' + ($WithState ? ',?\s+(CO|Colorado)\b' : '(?!\w)')
    if ($Text -match $pattern -and -not $found.Contains($city)) { $found.Add($city) }
  }
  $found.ToArray()
}

function Get-WbCityClue {
  <#
  .SYNOPSIS
    Infers an event's city from its venue, title, and description, or returns $null.
  .DESCRIPTION
    Tries clues from strongest to weakest and stops at the first that names cities:
    1. a Colorado ZIP code in the venue or description
    2. "City, CO" or "City, Colorado" anywhere, or "(City)" in the title
    3. a city name in the venue
    4. a known place from data/schema/place-cities.json, such as Pearl Street Mall
    5. the venue's city, when other events place that venueKey in one city
    6. "in", "downtown", or "at" before a city name in the title or description
    7. a city name in the title
    8. a city name in the description
    A clue that names more than one city is ambiguous and ends the search with no answer.
    Superior, Erie, and Lyons count only from clues 1 and 2. Names in the
    ignore list there, such as Boulder County, are not read as a city.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][object]$Event,
    [hashtable]$VenueCities = @{}
  )

  $venue = Remove-WbNonPlace "$($Event.venue)"
  $title = Remove-WbNonPlace "$($Event.title)"
  $description = Remove-WbNonPlace "$($Event.description)"
  $all = "$venue`n$title`n$description"

  # Each step runs only if the ones before it found nothing.
  $steps = @(
    { @([regex]::Matches("$venue`n$description", '\b80\d{3}\b') | ForEach-Object { $script:WbZipCities[$_.Value] }) }
    { @(Find-WbCityWord $all -WithState) + @(Find-WbCityWord $title -Before '\(\s*' | Where-Object { $title -match ('(?i)\(\s*' + [regex]::Escape($_) + '\s*\)') }) }
    { Find-WbCityWord $venue -Unambiguous }
    { Find-WbPlace $all }
    { @(if ($VenueCities.ContainsKey("$($Event.venueKey)")) { $VenueCities["$($Event.venueKey)"] }) }
    { Find-WbCityWord "$title`n$description" -Unambiguous -Before '\b(in|downtown|at)\s+(the\s+)?' }
    { Find-WbCityWord $title -Unambiguous }
    { Find-WbCityWord $description -Unambiguous }
  )
  foreach ($step in $steps) {
    $cities = @(& $step | Where-Object { $_ } | Select-Object -Unique)
    if ($cities.Count -eq 1) { return $cities[0] }
    if ($cities.Count -gt 1) { return $null }
  }
  $null
}

function Get-WbVenueCities {
  # venueKey to city, for venues that events with a real city place in exactly one city.
  # A venue that also appears with city Other is a placeholder ("Various Boulder County locations"),
  # not a place, so it is left out even when a merge gave one of its events a city.
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $seen = @{}
  $placeholders = [Collections.Generic.HashSet[string]]::new()
  foreach ($event in $Events) {
    if (-not $event.venueKey) { continue }
    if (-not $event.city -or $event.city -eq 'Other') { $null = $placeholders.Add($event.venueKey); continue }
    if (-not $seen.ContainsKey($event.venueKey)) { $seen[$event.venueKey] = [Collections.Generic.HashSet[string]]::new() }
    $null = $seen[$event.venueKey].Add($event.city)
  }
  $map = @{}
  foreach ($key in $seen.Keys) {
    if ($seen[$key].Count -eq 1 -and -not $placeholders.Contains($key)) { $map[$key] = @($seen[$key])[0] }
  }
  $map
}

function Resolve-WbOtherCity {
  <#
  .SYNOPSIS
    Sets the city on events stored as Other when their text says where they are. Returns how many changed.
  .DESCRIPTION
    Only the city changes. The id is built from title, date, and venue, so it stays the same.
  .PARAMETER Known
    Extra events to learn venue cities from, such as the archive. The Events are always used.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events,
    [AllowEmptyCollection()][object[]]$Known = @()
  )

  $venueCities = Get-WbVenueCities (@($Events) + @($Known))
  $changed = 0
  foreach ($event in $Events) {
    if ($event.city -and $event.city -ne 'Other') { continue }
    $city = Get-WbCityClue $event -VenueCities $venueCities
    if ($city) {
      $event | Add-Member -NotePropertyName city -NotePropertyValue $city -Force
      $changed++
    }
  }
  $changed
}

function Resolve-WbTitleVenue {
  <#
  .SYNOPSIS
    Gives an event at a placeholder venue the venue its title names. Returns how many changed.
  .DESCRIPTION
    Aggregators list many events under one placeholder ("Various Boulder County locations",
    city Other) while the title names the place: "Story Time at Boulder Public Library", "Sunday
    Brunch | Chautauqua Dining Hall". When the title ends in a known venue after "|", "@", a spaced
    dash, "at", or "at the", the event takes that venue's name, key, and city, and its id and size
    are rebuilt to match. After "|", "@", or a dash the venue is also dropped from the title, as
    New-WbEvent does; after "at" the title reads naturally and stays. Known venues are those other
    events place in exactly one city (Get-WbVenueCities), and the places in
    data/schema/place-cities.json. Anything else is left alone, since the words may name an event
    ("at Boulder County Festival of Trees", "| Dog Winter Photo Sessions"), not a place. Run it
    before Merge-WbEvents, so the event can merge with the venue's own listing.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $venueCities = Get-WbVenueCities $Events
  $names = @{}
  foreach ($event in $Events) {
    if ($event.venueKey -and $venueCities.ContainsKey($event.venueKey) -and -not $names.ContainsKey($event.venueKey)) {
      $names[$event.venueKey] = $event.venue
    }
  }

  $placeholders = @{}
  foreach ($event in $Events) {
    if ($event.venueKey -and -not $venueCities.ContainsKey($event.venueKey)) { $placeholders[$event.venueKey] = $true }
  }
  $places = (Get-WbPlaceCities).places
  foreach ($place in $places.Keys) {
    $key = Get-VenueKey $place
    if (-not $venueCities.ContainsKey($key)) {
      $venueCities[$key] = $places[$place]
      $names[$key] = $place
    }
  }

  $separator = "\s*[|@]\s*|\s+(?:-|$([char]0x2013)|$([char]0x2014))\s+"
  $changed = 0
  foreach ($event in $Events) {
    if (-not $placeholders.ContainsKey("$($event.venueKey)")) { continue }
    if ($event.city -and $event.city -ne 'Other') { continue }
    $title = "$($event.title)"
    $key = $null
    $rest = $null
    foreach ($pattern in @("^(?<rest>.+)(?:$separator)(?<the>)(?<venue>[^|@]+?)\s*[!.]?$", '^(?<keep>.+\sat\s+(?<the>the\s+)?(?<venue>.+?))\s*[!.]?$')) {
      $match = [regex]::Match($title, $pattern, 'IgnoreCase')
      if (-not $match.Success) { continue }
      $named = $match.Groups['venue'].Value
      # A bare city ("| Lafayette") says where, not at what venue.
      if (Resolve-WbCity $named.Trim()) { continue }
      foreach ($candidate in @("$($match.Groups['the'].Value)$named", $named)) {
        $try = Get-VenueKey $candidate
        $alias = Resolve-WbVenueAlias $try
        if ($alias) { $try = $alias.key }
        if ($venueCities.ContainsKey($try) -and -not $placeholders.ContainsKey($try)) { $key = $try; break }
      }
      if ($key) {
        if ($match.Groups['rest'].Success -and $match.Groups['rest'].Value.Trim().Length -ge 3) { $rest = $match.Groups['rest'].Value.Trim() }
        break
      }
    }
    if (-not $key) { continue }

    if ($rest) { $event | Add-Member -NotePropertyName title -NotePropertyValue $rest -Force }
    $event | Add-Member -NotePropertyName venue -NotePropertyValue $names[$key] -Force
    $event | Add-Member -NotePropertyName venueKey -NotePropertyValue $key -Force
    $event | Add-Member -NotePropertyName city -NotePropertyValue $venueCities[$key] -Force
    $event | Add-Member -NotePropertyName id -NotePropertyValue (Get-WbEventId $event.title $event.start $key) -Force
    $event | Add-Member -NotePropertyName size -NotePropertyValue (Get-WbEventSize -VenueKey $key -Category $event.category -Tags @($event.tags)) -Force
    $changed++
  }
  $changed
}
