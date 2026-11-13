BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Schema.ps1"

  function New-TestEvent {
    param([hashtable]$Overrides = @{})
    $arguments = @{
      Title    = 'Test Show'
      Start    = '2026-11-14T19:30:00-07:00'
      Venue    = 'Macky Auditorium'
      Url      = 'https://example.test/show'
      City     = 'Boulder'
      Category = 'music'
      Sources  = @(@{ name = 'a'; url = 'https://example.test/show'; fetchedAt = '2026-11-01T10:00:00Z' })
    }
    foreach ($key in $Overrides.Keys) { $arguments[$key] = $Overrides[$key] }
    New-WbEvent @arguments
  }
}

Describe 'ConvertTo-BoulderTime' {
  It 'uses the standard offset in winter' {
    ConvertTo-BoulderTime '2026-11-14T19:30:00' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'uses the daylight offset in summer' {
    ConvertTo-BoulderTime '2026-07-04T21:00:00' | Should -Be '2026-07-04T21:00:00-06:00'
  }

  It 'converts a UTC string' {
    ConvertTo-BoulderTime '2026-11-15T02:30:00Z' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'converts a string with an explicit offset' {
    ConvertTo-BoulderTime '2026-11-14T21:30:00-05:00' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'reads a zoneless string in the source time zone' {
    ConvertTo-BoulderTime '2026-11-14T21:30:00' 'America/New_York' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'ignores the source time zone when the value has an offset' {
    ConvertTo-BoulderTime '2026-11-15T02:30:00Z' 'America/New_York' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'reads an unspecified DateTime in the source time zone' {
    $value = [DateTime]::new(2026, 11, 14, 21, 30, 0, [DateTimeKind]::Unspecified)
    ConvertTo-BoulderTime $value 'America/New_York' | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'converts a UTC DateTime' {
    $value = [DateTime]::new(2026, 11, 15, 2, 30, 0, [DateTimeKind]::Utc)
    ConvertTo-BoulderTime $value | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'converts a DateTimeOffset' {
    $value = [DateTimeOffset]::new(2026, 11, 15, 2, 30, 0, [TimeSpan]::Zero)
    ConvertTo-BoulderTime $value | Should -Be '2026-11-14T19:30:00-07:00'
  }

  It 'moves the date when the conversion crosses midnight' {
    ConvertTo-BoulderTime '2026-10-30T01:00:00Z' | Should -Be '2026-10-29T19:00:00-06:00'
  }

  It 'gives each side of the fall DST change its own offset' {
    ConvertTo-BoulderTime '2026-11-01T07:30:00Z' | Should -Be '2026-11-01T01:30:00-06:00'
    ConvertTo-BoulderTime '2026-11-01T08:30:00Z' | Should -Be '2026-11-01T01:30:00-07:00'
  }
}

Describe 'Get-VenueKey' {
  It 'slugifies <name>' -ForEach @(
    @{ name = 'Macky Auditorium'; want = 'macky-auditorium' }
    @{ name = "Murphy's  Pub"; want = 'murphys-pub' }
    @{ name = 'Rock & Roll Hall'; want = 'rock-and-roll-hall' }
    @{ name = 'Café Olé!'; want = 'cafe-ole' }
    @{ name = '  --Trim Me-- '; want = 'trim-me' }
  ) {
    Get-VenueKey $name | Should -Be $want
  }
}

Describe 'Get-NormalizedTitle' {
  It 'ignores case, punctuation, and spacing' {
    Get-NormalizedTitle "Olivia O'Brien: The  PIXIE Tour!" | Should -Be 'olivia obrien the pixie tour'
  }

  It 'treats curly and straight apostrophes alike' {
    Get-NormalizedTitle "O$([char]0x2019)Brien" | Should -Be (Get-NormalizedTitle "O'Brien")
  }
}

Describe 'Resolve-WbCity' {
  It 'maps <name> to <want>' -ForEach @(
    @{ name = 'boulder'; want = 'Boulder' }
    @{ name = 'LONGMONT'; want = 'Longmont' }
    @{ name = ' Nederland '; want = 'Nederland' }
    @{ name = 'Gunbarrel'; want = 'Boulder' }
    @{ name = 'gunbarrel'; want = 'Boulder' }
  ) {
    Resolve-WbCity $name | Should -Be $want
  }

  It 'returns nothing for a place outside the list' {
    Resolve-WbCity 'Estes Park' | Should -BeNullOrEmpty
  }
}

Describe 'ConvertFrom-WbLocation' {
  BeforeAll {
    $source = [pscustomobject]@{ venue = 'University of Colorado Boulder'; venueKey = 'university-of-colorado-boulder'; city = 'Other' }
  }

  It 'reads <location>' -ForEach @(
    @{ location = 'Boulder, Colorado, Macky Auditorium'; venue = 'Macky Auditorium'; key = 'macky-auditorium'; city = 'Boulder' }
    @{ location = 'Boulder Theater, Boulder, Colorado'; venue = 'Boulder Theater'; key = 'boulder-theater'; city = 'Boulder' }
    @{ location = 'Lafayette, CO, Bob L. Burger Recreation Center'; venue = 'Bob L. Burger Recreation Center'; key = 'bob-l-burger-recreation-center'; city = 'Lafayette' }
    @{ location = 'Imig Music Building (MUS), Grusin Music Hall, C199'; venue = 'Imig Music Building'; key = 'imig-music-building'; city = 'Other' }
    @{ location = '123 Main St, Niwot, CO 80544'; venue = '123 Main St'; key = '123-main-st'; city = 'Niwot' }
    @{ location = 'Avery Brewing, 4910 Nautilus Ct N, Gunbarrel, CO, 80301, United States'; venue = 'Avery Brewing'; key = 'avery-brewing'; city = 'Boulder' }
    @{ location = 'Eldora Mountain Resort, 2861 Eldora Ski Rd, Nederland, CO, 80466'; venue = 'Eldora Mountain Resort'; key = 'eldora-mountain-resort'; city = 'Nederland' }
  ) {
    $result = ConvertFrom-WbLocation $location -Source $source
    $result.Venue | Should -Be $venue
    $result.VenueKey | Should -Be $key
    $result.City | Should -Be $city
  }

  It 'falls back when only a city is given' {
    $result = ConvertFrom-WbLocation 'Boulder, Colorado' -Source $source
    $result.Venue | Should -Be 'University of Colorado Boulder'
    $result.VenueKey | Should -Be 'university-of-colorado-boulder'
    $result.City | Should -Be 'Boulder'
  }

  It 'falls back when the location is empty' {
    (ConvertFrom-WbLocation '' -Source $source).Venue | Should -Be 'University of Colorado Boulder'
  }
}

Describe 'ConvertTo-WbTitleCase' {
  It 'title-cases an all-caps title and keeps acronyms: <title>' -ForEach @(
    @{ title = 'OLD BOULDER MODEL RAILROAD'; want = 'Old Boulder Model Railroad' }
    @{ title = 'THE LEGEND OF KORRA IN CONCERT'; want = 'The Legend of Korra in Concert' }
    @{ title = 'TAYLOR TOMLINSON: NOBODY ASKED YOU TO DO THAT'; want = 'Taylor Tomlinson: Nobody Asked You to Do That' }
    @{ title = 'DJ NITES ON THE ICE WITH DJ MATEO & FRIENDS!'; want = 'DJ Nites on the Ice with DJ Mateo & Friends!' }
    @{ title = "BOB SMITH'S ANNUAL HOMECOMING RUN"; want = "Bob Smith's Annual Homecoming Run" }
    @{ title = '2027 WARRIOR/ECHL ALL STAR CLASSIC'; want = '2027 Warrior/ECHL All Star Classic' }
    @{ title = 'SPIRITUAL RECOVERY SUPPORT GROUP- CSL SOUL RECOVERY'; want = 'Spiritual Recovery Support Group- CSL Soul Recovery' }
    @{ title = 'KARAOKE IN THE BASEMENT! (21+)'; want = 'Karaoke in the Basement! (21+)' }
    @{ title = 'LEGO CLUB'; want = 'LEGO Club' }
    @{ title = 'CHVRCHES - LIVE 2027'; want = 'Chvrches - Live 2027' }
    @{ title = 'CSU @ CU'; want = 'CSU @ CU' }
    @{ title = 'PRESCHOOL STEAM STORYTIME'; want = 'Preschool STEAM Storytime' }
    @{ title = 'LIVE FROM ETOWN HALL'; want = 'Live From eTown Hall' }
    @{ title = 'ROCKY II AT THE BOULDER THEATER'; want = 'Rocky II at the Boulder Theater' }
  ) {
    ConvertTo-WbTitleCase $title | Should -BeExactly $want
  }

  It 'leaves a title that has lowercase letters, or is one word: <title>' -ForEach @(
    @{ title = 'Bingo NIGHT at the VFW' }
    @{ title = 'KREAM' }
    @{ title = 'BUNT.' }
    @{ title = 'Music & Movement' }
    @{ title = 'oldspeak' }
  ) {
    ConvertTo-WbTitleCase $title | Should -BeExactly $title
  }

  It 'title-cases an all-lowercase title, without keepUpper: <title>' -ForEach @(
    @{ title = 'colorado art gallery'; want = 'Colorado Art Gallery' }
    @{ title = 'come paint with us at the cu center'; want = 'Come Paint with Us at the Cu Center' }
    @{ title = 'dj night on st patrick''s day'; want = 'DJ Night on St Patrick''s Day' }
    @{ title = 'live from etown hall'; want = 'Live From eTown Hall' }
  ) {
    ConvertTo-WbTitleCase $title | Should -BeExactly $want
  }
}

Describe 'New-WbEvent' {
  It 'title-cases an all-caps title' {
    (New-TestEvent @{ Title = 'OLD BOULDER MODEL RAILROAD' }).title | Should -BeExactly 'Old Boulder Model Railroad'
  }

  It 'title-cases an all-lowercase venue' {
    (New-TestEvent @{ Venue = 'colorado art gallery' }).venue | Should -BeExactly 'Colorado Art Gallery'
  }

  It 'drops the venue from the end of a title, since the venue is shown beside it: <title>' -ForEach @(
    @{ title = 'Music & Movement | Lafayette Public Library'; venue = 'Lafayette Public Library'; want = 'Music & Movement' }
    @{ title = "Karoake Friday @ Murphy's Tap House"; venue = "Murphy's Tap House"; want = 'Karoake Friday' }
    @{ title = 'Coffee with a Vet - Sanitas Brewing'; venue = 'Sanitas Brewing'; want = 'Coffee with a Vet' }
    @{ title = 'Preschool STEAM Storytime | lafayette public library'; venue = 'Lafayette Public Library'; want = 'Preschool STEAM Storytime' }
  ) {
    (New-TestEvent @{ Title = $title; Venue = $venue; City = 'Lafayette' }).title | Should -Be $want
  }

  It 'keeps a title whose venue is joined by "at", or that is only the venue, or has it mid-title: <title>' -ForEach @(
    @{ title = 'Winter Skate at The Village'; venue = 'The Village' }
    @{ title = 'Lafayette Public Library'; venue = 'Lafayette Public Library' }
    @{ title = 'Fix-It Night'; venue = 'It Night' }
    @{ title = 'Community Cycles | Fix-It Night'; venue = 'Community Cycles' }
  ) {
    (New-TestEvent @{ Title = $title; Venue = $venue }).title | Should -Be $title
  }

  It 'computes the documented id' {
    $seed = 'test show|2026-11-14|macky-auditorium'
    $hash = [Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($seed))
    $want = [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
    (New-TestEvent).id | Should -Be $want
  }

  It 'gives the same id across punctuation and case' {
    (New-TestEvent @{ Title = 'TEST SHOW!' }).id | Should -Be (New-TestEvent).id
  }

  It 'gives a different id on a different date' {
    (New-TestEvent @{ Start = '2026-11-15T19:30:00-07:00' }).id | Should -Not -Be (New-TestEvent).id
  }

  It 'derives venueKey from the venue' {
    (New-TestEvent).venueKey | Should -Be 'macky-auditorium'
  }

  It 'keeps an explicit venueKey' {
    (New-TestEvent @{ VenueKey = 'custom-key' }).venueKey | Should -Be 'custom-key'
  }

  It 'defaults allDay to false and omits empty optional fields' {
    $event = New-TestEvent
    $event.allDay | Should -BeFalse
    $event.PSObject.Properties.Name | Should -Not -Contain 'end'
    $event.PSObject.Properties.Name | Should -Not -Contain 'description'
  }

  It 'builds an all-day event' {
    $event = New-TestEvent @{ Start = '2026-11-14'; AllDay = $true }
    $event.allDay | Should -BeTrue
    $event.start | Should -Be '2026-11-14'
  }

  It 'strips markup from the description' {
    (New-TestEvent @{ Description = '<p>Fish &amp; chips</p>' }).description | Should -Be 'Fish & chips'
  }

  It 'drops sentences with a ticket price' {
    $text = 'Doors at 7 PM. Tickets $32.75 on DICE, fees included. All ages!'
    (New-TestEvent @{ Description = $text }).description | Should -Be 'Doors at 7 PM. All ages!'
  }

  It 'omits a description that was only a price' {
    (New-TestEvent @{ Description = 'Tickets are $20' }).PSObject.Properties.Name | Should -Not -Contain 'description'
  }

  It 'truncates the description to 300 characters' {
    $event = New-TestEvent @{ Description = 'x' * 500 }
    $event.description.Length | Should -Be 300
    $event.description | Should -BeLike '*...'
  }

  It 'never cuts an emoji in half when it truncates the description' {
    # 296 letters, then an emoji (two UTF-16 halves) across the cut at 297.
    $musicNote = [char]::ConvertFromUtf32(0x1F3B6)
    $event = New-TestEvent @{ Description = ('x' * 296) + $musicNote + ('y' * 50) }
    $event.description | Should -BeExactly (('x' * 296) + '...')
  }

  It 'keeps a sources array with a single entry' {
    $event = New-TestEvent
    @($event.sources).Count | Should -Be 1
    (ConvertTo-Json $event -Depth 6) | Should -Match '"sources": \['
  }

  It 'rejects a timed event with no offset' {
    { New-TestEvent @{ Start = '2026-11-14T19:30:00' } } | Should -Throw '*schema*'
  }

  It 'rejects an all-day event with a time' {
    { New-TestEvent @{ Start = '2026-11-14T19:30:00-07:00'; AllDay = $true } } | Should -Throw '*schema*'
  }

  It 'rejects a city outside the enum' {
    { New-TestEvent @{ City = 'Denver' } } | Should -Throw '*schema*'
  }
}

Describe 'Test-WbEvent' {
  It 'accepts a built event' {
    Test-WbEvent (New-TestEvent) | Should -BeTrue
  }

  It 'rejects an event with extra fields' {
    $event = New-TestEvent
    $event | Add-Member -NotePropertyName image -NotePropertyValue 'https://example.test/i.png'
    Test-WbEvent $event | Should -BeFalse
  }
}
