BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Store.ps1"

  function New-TestEvent {
    param(
      [string]$Title = 'Show',
      [string]$Start = '2026-11-14T19:30:00-07:00',
      [string]$End,
      [string[]]$Source = @('a'),
      [string]$FetchedAt = '2026-11-01T10:00:00Z',
      [switch]$AllDay
    )
    $sources = $Source | ForEach-Object { @{ name = $_; url = "https://$_.test/e"; fetchedAt = $FetchedAt } }
    New-WbEvent -Title $Title -Start $Start -End $End -AllDay:$AllDay -Venue 'Venue' -Category 'music' -Url 'https://x.test/e' -Sources $sources
  }

  $script:now = [DateTimeOffset]::Parse('2026-11-14T20:00:00-07:00')
}

Describe 'Test-WbEventPast' {
  It 'is past once a timed event has started and has no end' {
    Test-WbEventPast (New-TestEvent -Start '2026-11-14T19:30:00-07:00') $now | Should -BeTrue
    Test-WbEventPast (New-TestEvent -Start '2026-11-14T20:30:00-07:00') $now | Should -BeFalse
  }

  It 'is not past while a timed event is running' {
    $event = New-TestEvent -Start '2026-11-14T19:30:00-07:00' -End '2026-11-14T22:00:00-07:00'
    Test-WbEventPast $event $now | Should -BeFalse
  }

  It 'keeps an all-day event through its last day' {
    Test-WbEventPast (New-TestEvent -Start '2026-11-14' -AllDay) $now | Should -BeFalse
    Test-WbEventPast (New-TestEvent -Start '2026-11-13' -AllDay) $now | Should -BeTrue
  }

  It 'keeps a multi-day all-day event until its end date passes' {
    Test-WbEventPast (New-TestEvent -Start '2026-11-10' -End '2026-11-14' -AllDay) $now | Should -BeFalse
  }
}

Describe 'Get-CarriedWbEvents' {
  It 'keeps past events for the archive even from refreshed sources' {
    $event = New-TestEvent -Start '2026-11-01T19:00:00-06:00'
    @(Get-CarriedWbEvents @($event) -Refreshed @('a') -Enabled @('a') -Now $now).Count | Should -Be 1
  }

  It 'drops upcoming events from a refreshed source, so removed events go away' {
    $event = New-TestEvent -Start '2026-12-01T19:00:00-07:00'
    @(Get-CarriedWbEvents @($event) -Refreshed @('a') -Enabled @('a') -Now $now).Count | Should -Be 0
  }

  It 'keeps upcoming events from a source that was not refreshed' {
    $event = New-TestEvent -Start '2026-12-01T19:00:00-07:00'
    @(Get-CarriedWbEvents @($event) -Refreshed @('b') -Enabled @('a', 'b') -Now $now).Count | Should -Be 1
  }

  It 'removes only the refreshed source from a shared event' {
    $event = New-TestEvent -Start '2026-12-01T19:00:00-07:00' -Source a, b
    $carried = @(Get-CarriedWbEvents @($event) -Refreshed @('a') -Enabled @('a', 'b') -Now $now)
    @($carried[0].sources).name | Should -Be 'b'
    @($event.sources).Count | Should -Be 2
  }

  It 'drops upcoming events from a source that was disabled or removed' {
    $event = New-TestEvent -Start '2026-12-01T19:00:00-07:00'
    @(Get-CarriedWbEvents @($event) -Refreshed @('b') -Enabled @('b') -Now $now).Count | Should -Be 0
  }
}

Describe 'Restore-WbFetchedAt' {
  It 'keeps the stored timestamp for a known event and source' {
    $stored = New-TestEvent -FetchedAt '2026-10-01T10:00:00Z'
    $fresh = New-TestEvent -FetchedAt '2026-11-01T10:00:00Z'
    Restore-WbFetchedAt @($fresh) @($stored)
    $fresh.sources[0].fetchedAt | Should -Be '2026-10-01T10:00:00Z'
  }

  It 'leaves a new source alone' {
    $stored = New-TestEvent -Source a -FetchedAt '2026-10-01T10:00:00Z'
    $fresh = New-TestEvent -Source b -FetchedAt '2026-11-01T10:00:00Z'
    Restore-WbFetchedAt @($fresh) @($stored)
    $fresh.sources[0].fetchedAt | Should -Be '2026-11-01T10:00:00Z'
  }
}

Describe 'Write-WbEventFile and Read-WbEventFile' {
  BeforeEach {
    $path = Join-Path $TestDrive 'data' 'events.json'
  }

  It 'round-trips start times unchanged' {
    Write-WbEventFile $path @(New-TestEvent)
    (Read-WbEventFile $path).start | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'writes LF endings, 2-space indents, a final newline, and no BOM' {
    Write-WbEventFile $path @(New-TestEvent)
    $bytes = [IO.File]::ReadAllBytes($path)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $text | Should -Not -Match "`r"
    $text | Should -Match "`n  \{`n    `"id`""
    $bytes[-1] | Should -Be 10
    $bytes[0] | Should -Be ([byte][char]'[')
  }

  It 'writes one event as an array' {
    Write-WbEventFile $path @(New-TestEvent)
    (Get-Content $path -Raw).TrimStart() | Should -BeLike '`[*'
  }

  It 'writes an empty array' {
    Write-WbEventFile $path @()
    (Get-Content $path -Raw).Trim() | Should -Be '[]'
    @(Read-WbEventFile $path).Count | Should -Be 0
  }

  It 'returns nothing for a missing file' {
    @(Read-WbEventFile (Join-Path $TestDrive 'nope.json')).Count | Should -Be 0
  }
}

Describe 'Sort-WbEvents' {
  It 'sorts by instant, then id' {
    $later = New-TestEvent -Title 'Later' -Start '2026-11-15T19:30:00-07:00'
    $early = New-TestEvent -Title 'Early' -Start '2026-11-14T19:30:00-07:00'
    $allDay = New-TestEvent -Title 'All day' -Start '2026-11-14' -AllDay
    (Sort-WbEvents @($later, $early, $allDay)).title | Should -Be @('All day', 'Early', 'Later')
  }
}

Describe 'Add-WbArchive' {
  It 'splits events by the month of their start' {
    $directory = Join-Path $TestDrive 'split'
    Add-WbArchive $directory @(
      (New-TestEvent -Start '2026-10-31T19:00:00-06:00')
      (New-TestEvent -Start '2026-11-01T19:00:00-06:00')
    )
    (Get-ChildItem $directory).Name | Should -Be @('2026-10.json', '2026-11.json')
  }

  It 'appends to a month and dedupes within it' {
    $directory = Join-Path $TestDrive 'append'
    Add-WbArchive $directory @(New-TestEvent -Title 'First' -Start '2026-10-01T19:00:00-06:00')
    Add-WbArchive $directory @(
      (New-TestEvent -Title 'Second' -Start '2026-10-02T19:00:00-06:00')
      (New-TestEvent -Title 'First' -Start '2026-10-01T19:00:00-06:00')
    )
    (Read-WbEventFile (Join-Path $directory '2026-10.json')).title | Should -Be @('First', 'Second')
  }

  It 'writes the same bytes when run again on the same events' {
    $directory = Join-Path $TestDrive 'stable'
    $path = Join-Path $directory '2026-10.json'
    Add-WbArchive $directory @(New-TestEvent -Start '2026-10-01T19:00:00-06:00' -FetchedAt '2026-10-01T10:00:00Z')
    $before = Get-Content $path -Raw
    Add-WbArchive $directory @(New-TestEvent -Start '2026-10-01T19:00:00-06:00' -FetchedAt '2026-11-01T10:00:00Z')
    Get-Content $path -Raw | Should -Be $before
  }

  It 'does nothing for no events' {
    $directory = Join-Path $TestDrive 'none'
    Add-WbArchive $directory @()
    Test-Path $directory | Should -BeFalse
  }
}
