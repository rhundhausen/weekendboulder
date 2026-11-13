BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Dedupe.ps1"

  function New-TestEvent {
    param(
      [string]$Title = 'Boulder Philharmonic Season Opener',
      [string]$Start = '2026-11-14T19:30:00-07:00',
      [string]$End,
      [string]$City = 'Boulder',
      [string]$Venue = 'Macky Auditorium',
      [string]$Source = 'a',
      [string]$Url = "https://$Source.test/e",
      [string]$Description,
      [string]$FetchedAt = '2026-11-01T10:00:00Z',
      [switch]$AllDay
    )
    New-WbEvent -Title $Title -Start $Start -End $End -City $City -Venue $Venue -Category 'music' -Url $Url -Description $Description -AllDay:$AllDay `
      -Sources @(@{ name = $Source; url = $Url; fetchedAt = $FetchedAt })
  }
}

Describe 'Get-JaroWinkler' {
  It 'scores <first> and <second>' -ForEach @(
    @{ first = 'MARTHA'; second = 'MARHTA'; want = 0.9611 }
    @{ first = 'DIXON'; second = 'DICKSONX'; want = 0.8133 }
    @{ first = 'DWAYNE'; second = 'DUANE'; want = 0.84 }
    @{ first = 'same'; second = 'same'; want = 1 }
    @{ first = 'abc'; second = 'xyz'; want = 0 }
    @{ first = ''; second = 'abc'; want = 0 }
  ) {
    Get-JaroWinkler $first $second | Should -BeLessOrEqual ($want + 0.0001)
    Get-JaroWinkler $first $second | Should -BeGreaterOrEqual ($want - 0.0001)
  }

  It 'is case sensitive' {
    Get-JaroWinkler 'ABC' 'abc' | Should -Be 0
  }
}

Describe 'Merge-WbEvents' {
  It 'merges events with the same id' {
    $merged = @(Merge-WbEvents @((New-TestEvent -Source a), (New-TestEvent -Source b)))
    $merged.Count | Should -Be 1
    $merged[0].sources.name | Should -Be @('a', 'b')
  }

  It 'merges similar titles at the same venue within 30 minutes' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Boulder Philharmonic Season Opener' -Source a)
        (New-TestEvent -Title 'Boulder Philharmonic Season Openers' -Start '2026-11-14T20:00:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'keeps events 31 minutes apart' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Boulder Philharmonic Season Opener' -Source a)
        (New-TestEvent -Title 'Boulder Philharmonic Season Openers' -Start '2026-11-14T20:01:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }

  It 'merges across midnight' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'New Years Eve Countdown Party' -Start '2026-12-31T23:50:00-07:00' -Source a)
        (New-TestEvent -Title 'New Years Eve Countdown Parties' -Start '2027-01-01T00:10:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'keeps similar titles at different venues' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Boulder Philharmonic Season Opener' -Venue 'Macky Auditorium')
        (New-TestEvent -Title 'Boulder Philharmonic Season Openers' -Venue 'Boulder Theater')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps different titles at the same time and venue' {
    $merged = @(Merge-WbEvents @((New-TestEvent -Title 'Comedy Night'), (New-TestEvent -Title 'Boulder Ballet Nutcracker')))
    $merged.Count | Should -Be 2
  }

  It 'keeps the longest description' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Source a -Description 'Short')
        (New-TestEvent -Source b -Description 'A much longer description')
      ) -Priorities @{ a = 1; b = 99 })
    $merged[0].description | Should -Be 'A much longer description'
  }

  It 'adds a description the preferred source lacks' {
    $merged = @(Merge-WbEvents @((New-TestEvent -Source a), (New-TestEvent -Source b -Description 'Only here')) -Priorities @{ a = 1; b = 99 })
    $merged[0].description | Should -Be 'Only here'
  }

  It 'prefers the url from the lowest priority number, whatever the input order' {
    $first = New-TestEvent -Source a
    $second = New-TestEvent -Source b
    (Merge-WbEvents @($first, $second) -Priorities @{ a = 10; b = 90 }).url | Should -Be 'https://a.test/e'
    (Merge-WbEvents @($second, $first) -Priorities @{ a = 10; b = 90 }).url | Should -Be 'https://a.test/e'
    (Merge-WbEvents @($first, $second) -Priorities @{ a = 90; b = 10 }).url | Should -Be 'https://b.test/e'
  }

  It 'breaks a priority tie by input order, however many reports there are' {
    # 100 equal-priority reports of one show mixed in with 200 other events. Sort-Object without
    # -Stable reorders ties in a list like this, and a later source's url won.
    $reports = @(1..300 | ForEach-Object {
        if ($_ % 3 -eq 0) { New-TestEvent -Source ('s{0:d3}' -f $_) }
        else { New-TestEvent -Title "Other Show $_" -Venue "Hall $_" -Source x }
      })
    $show = $reports[2].id
    (@(Merge-WbEvents $reports) | Where-Object id -eq $show).url | Should -Be 'https://s003.test/e'
    [array]::Reverse($reports)
    (@(Merge-WbEvents $reports) | Where-Object id -eq $show).url | Should -Be 'https://s300.test/e'
  }

  It 'treats a missing priority as 50' {
    (Merge-WbEvents @((New-TestEvent -Source a), (New-TestEvent -Source b)) -Priorities @{ b = 40 }).url | Should -Be 'https://b.test/e'
    (Merge-WbEvents @((New-TestEvent -Source a), (New-TestEvent -Source b)) -Priorities @{ b = 60 }).url | Should -Be 'https://a.test/e'
  }

  It 'unions sources with one entry per name and the earliest fetchedAt' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Source a -FetchedAt '2026-11-02T10:00:00Z')
        (New-TestEvent -Source a -FetchedAt '2026-11-01T10:00:00Z')
        (New-TestEvent -Source b)
      ))
    @($merged[0].sources).Count | Should -Be 2
    ($merged[0].sources | Where-Object name -eq 'a').fetchedAt | Should -Be '2026-11-01T10:00:00Z'
  }

  It 'merges three reports that chain together' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Source a)
        (New-TestEvent -Title 'Boulder Philharmonic Season Openers' -Source b)
        (New-TestEvent -Source c)
      ))
    $merged.Count | Should -Be 1
    @($merged[0].sources).Count | Should -Be 3
  }

  It 'does not change its input' {
    $first = New-TestEvent -Source a
    $null = Merge-WbEvents @($first, (New-TestEvent -Source b -Description 'More'))
    @($first.sources).Count | Should -Be 1
    $first.PSObject.Properties.Name | Should -Not -Contain 'description'
  }

  It 'unions tags' {
    $first = New-TestEvent -Title 'Trivia Night' -Source a
    $second = New-TestEvent -Title 'Trivia Night' -Description 'Great for kids' -Source b
    @((Merge-WbEvents @($first, $second))[0].tags) | Should -Be @('kids', 'trivia')
  }

  It 'keeps a merged event valid when one report is all-day and one is timed' {
    $allDay = New-TestEvent -Start '2026-11-14' -AllDay -Source a
    $timed = New-WbEvent -Title 'Boulder Philharmonic Season Opener' -Start '2026-11-14T10:00:00-07:00' -End '2026-11-14T16:00:00-07:00' `
      -Venue 'Macky Auditorium' -Category 'music' -Url 'https://b.test/e' -Sources @(@{ name = 'b'; url = 'https://b.test/e'; fetchedAt = '2026-11-01T10:00:00Z' })
    foreach ($priorities in @{ a = 1; b = 2 }, @{ a = 2; b = 1 }) {
      $merged = @(Merge-WbEvents @($allDay, $timed) -Priorities $priorities)
      $merged.Count | Should -Be 1
      Test-WbEvent $merged[0] | Should -BeTrue
    }
  }

  It 'handles all-day events' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Start '2026-11-14' -AllDay -Source a)
        (New-TestEvent -Start '2026-11-14' -AllDay -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'returns nothing for no events' {
    @(Merge-WbEvents @()).Count | Should -Be 0
  }
}

Describe 'Test-WbSameTitleWords' {
  It '<first> and <second> match: <want>' -ForEach @(
    @{ first = 'Jo Koy'; second = 'Jo Koy (12 and Over)'; want = $true }
    @{ first = 'Jo Koy'; second = 'Jo Koy - Koy Meets World Tour'; want = $true }
    @{ first = "CU Women's Basketball Game"; second = "University of Colorado Women's Basketball vs Portland State - Trivia Friday"; want = $true }
    @{ first = 'JSTJR'; second = 'JSTJR, EZA, Elijah Andres'; want = $true }
    @{ first = 'Family Storytime'; second = 'Toddler Storytime'; want = $false }
    @{ first = 'Senior Recital: Natalie Li, saxophone'; second = 'Senior Recital: Eddie Rudser, clarinet'; want = $false }
    @{ first = 'The Show'; second = 'Live Tour'; want = $false }
  ) {
    $a = Get-WbTitleWords (Get-WbMatchTitle $first)
    $b = Get-WbTitleWords (Get-WbMatchTitle $second)
    Test-WbSameTitleWords $a $b | Should -Be $want
  }
}

Describe 'Merge-WbEvents same-minute rule' {
  It 'merges different titles for one show from different sources' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Jo Koy' -Venue 'CU Events Center' -Start '2026-11-07T20:00:00-07:00' -Source a)
        (New-TestEvent -Title 'Jo Koy (12 and Over)' -Venue 'CU Events Center' -Start '2026-11-07T20:00:00-07:00' -Source b)
        (New-TestEvent -Title 'Jo Koy - Koy Meets World Tour' -Venue 'CU Events Center' -Start '2026-11-07T20:00:00-07:00' -Source c)
      ) -Priorities @{ b = 10 })
    $merged.Count | Should -Be 1
    $merged[0].title | Should -Be 'Jo Koy (12 and Over)'
    $merged[0].sources.name | Should -Be @('a', 'b', 'c')
  }

  It 'merges a short-form title with the full one' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title "University of Colorado Women's Basketball vs Portland State - Trivia Friday" -Venue 'CU Events Center' -Start '2026-11-06T18:30:00-07:00' -Source athletics)
        (New-TestEvent -Title "CU Women's Basketball Game" -Venue 'CU Events Center' -Start '2026-11-06T18:30:00-07:00' -Source mom)
      ) -Priorities @{ athletics = 10; mom = 40 })
    $merged.Count | Should -Be 1
    $merged[0].title | Should -BeLike 'University of Colorado*'
  }

  It 'merges titles that share only their core, without presenter or subtitle' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Boulder Ballet presents The Nutcracker' -Start '2026-12-20T12:00:00-07:00' -Source a)
        (New-TestEvent -Title 'The Nutcracker: With Live Music by the Boulder Phil' -Start '2026-12-20T12:00:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 1
  }

  It 'keeps core matches apart at different venues' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Boulder Ballet presents The Nutcracker' -Start '2026-12-20T12:00:00-07:00' -Source a)
        (New-TestEvent -Title 'The Nutcracker: A Puppet Show' -Venue 'Boulder Theater' -Start '2026-12-20T12:00:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when the start differs by a minute or more' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Jo Koy' -Venue 'CU Events Center' -Start '2026-11-07T20:00:00-07:00' -Source a)
        (New-TestEvent -Title 'Jo Koy Late Show Extra' -Venue 'CU Events Center' -Start '2026-11-07T20:15:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps two listings from the same source' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Storytime' -Venue 'Boulder Public Library' -Start '2026-11-05T10:30:00-07:00' -Source library -Url 'https://library.test/1')
        (New-TestEvent -Title 'Toddler Storytime' -Venue 'Boulder Public Library' -Start '2026-11-05T10:30:00-07:00' -Source library -Url 'https://library.test/2')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps different titles at different venues' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Jo Koy' -Venue 'CU Events Center' -Start '2026-11-07T20:00:00-07:00' -Source a)
        (New-TestEvent -Title 'Jo Koy (12 and Over)' -Venue 'Macky Auditorium' -Start '2026-11-07T20:00:00-07:00' -Source b)
      ))
    $merged.Count | Should -Be 2
  }
}

Describe 'Merge-WbEvents multi-day rule' {
  BeforeAll {
    # Two sources for one festival: one reports the wrong opening time and another building.
    function New-Festival {
      param([string]$Source, [string]$Start, [string]$Venue, [string]$City = 'Longmont', [string]$End = '2026-11-30T17:00:00-07:00', [string]$Title = 'Longmont Festival of Trees')
      New-TestEvent -Title $Title -Start $Start -End $End -Venue $Venue -City $City -Source $Source -Url "https://$Source.test/trees"
    }
  }

  It 'merges one multi-day event that two sources list at different times and buildings' {
    $merged = @(Merge-WbEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Boulder County Fairgrounds Exhibit Building')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Boulder County Fairgrounds Barn')
      ) -Priorities @{ venue = 20 })
    $merged.Count | Should -Be 1
    $merged[0].url | Should -Be 'https://venue.test/trees'
    $merged[0].sources.name | Should -Be @('agency', 'venue')
  }

  It 'keeps them apart in different cities' {
    $merged = @(Merge-WbEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Boulder County Fairgrounds Barn')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Broomfield Auditorium' -City 'Broomfield')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when the city is unknown' {
    $merged = @(Merge-WbEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Hall A' -City 'Other')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Hall B' -City 'Other')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when they start on different days' {
    $merged = @(Merge-WbEvents @(
        (New-Festival -Source venue -Start '2026-11-27T12:00:00-07:00' -Venue 'Boulder County Fairgrounds Barn')
        (New-Festival -Source agency -Start '2026-11-28T12:00:00-07:00' -Venue 'Boulder County Fairgrounds Exhibit Building')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps them apart when the titles differ' {
    $merged = @(Merge-WbEvents @(
        (New-Festival -Source venue -Start '2026-11-27T06:30:00-07:00' -Venue 'Boulder County Fairgrounds Exhibit Building')
        (New-Festival -Source agency -Start '2026-11-27T12:00:00-07:00' -Venue 'Boulder County Fairgrounds Barn' -Title 'Longmont Festival of Lights')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps one-day events with the same title at different venues' {
    $merged = @(Merge-WbEvents @(
        (New-Festival -Source a -Start '2026-11-27T10:00:00-07:00' -End '2026-11-27T11:00:00-07:00' -Venue 'Library A' -Title 'Story Time')
        (New-Festival -Source b -Start '2026-11-27T14:00:00-07:00' -End '2026-11-27T15:00:00-07:00' -Venue 'Library B' -Title 'Story Time')
      ))
    $merged.Count | Should -Be 2
  }

  It 'keeps two listings from the same source' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Holiday Bazaar' -Start '2026-11-27T09:00:00-07:00' -End '2026-11-29T17:00:00-07:00' -Venue 'Hall A' -City 'Longmont' -Source s -Url 'https://s.test/1')
        (New-TestEvent -Title 'Holiday Bazaar' -Start '2026-11-27T10:00:00-07:00' -End '2026-11-29T17:00:00-07:00' -Venue 'Hall B' -City 'Longmont' -Source s -Url 'https://s.test/2')
      ))
    $merged.Count | Should -Be 2
  }
}

Describe 'Merge-WbEvents cross-venue rule' {
  It 'merges one show that sources place in different buildings, keeping the best source''s venue' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Taryn Smith & Christine Turpin' -Venue 'Macky Auditorium' -Start '2026-11-12T18:00:00-07:00' -Source dairy)
        (New-TestEvent -Title 'Taryn Smith & Christine Turpin' -Venue 'University Memorial Center' -Start '2026-11-12T18:00:00-07:00' -Source cu)
      ) -Priorities @{ dairy = 80; cu = 30 })
    $merged.Count | Should -Be 1
    $merged[0].venue | Should -Be 'University Memorial Center'
    @($merged[0].sources.name) | Should -Be @('cu', 'dairy')
  }

  It 'replaces a placeholder venue with the real one: <placeholder>' -ForEach @(
    @{ placeholder = 'Boulder' }
    @{ placeholder = 'Boulder, CO 80302' }
    @{ placeholder = 'Various Boulder County locations' }
  ) {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Boulder Half Marathon' -Venue $placeholder -Start '2026-11-14T09:00:00-07:00' -Source best)
        (New-TestEvent -Title 'Boulder Half Marathon' -Venue 'Chautauqua Park' -Start '2026-11-14T09:00:00-07:00' -Source other)
      ) -Priorities @{ best = 20; other = 80 })
    $merged.Count | Should -Be 1
    $merged[0].venue | Should -Be 'Chautauqua Park'
    $merged[0].url | Should -Be 'https://best.test/e'
  }

  It 'keeps them apart when <why>' -ForEach @(
    @{ why = 'the start differs'; second = @{ Start = '2026-11-12T18:15:00-07:00' } }
    @{ why = 'the city differs'; second = @{ City = 'Longmont' } }
    @{ why = 'the city is unknown'; first = @{ City = 'Other' }; second = @{ City = 'Other' } }
    @{ why = 'the titles differ'; second = @{ Title = 'Taryn Smith' } }
    @{ why = 'one source lists both'; second = @{ Source = 'a'; Url = 'https://a.test/2' } }
  ) {
    $base = @{ Title = 'Story Time'; Venue = 'Library A'; Start = '2026-11-12T18:00:00-07:00'; Source = 'a' }
    $one = $base.Clone(); if ($first) { foreach ($k in $first.Keys) { $one[$k] = $first[$k] } }
    $two = $base.Clone(); $two.Venue = 'Library B'; $two.Source = 'b'; foreach ($k in $second.Keys) { $two[$k] = $second[$k] }
    $merged = @(Merge-WbEvents @((New-TestEvent @one), (New-TestEvent @two)))
    $merged.Count | Should -Be 2
  }

  It 'leaves all-day events to the other rules' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Holiday Market' -Venue 'Hall A' -Start '2026-11-27' -AllDay -Source a)
        (New-TestEvent -Title 'Holiday Market' -Venue 'Hall B' -Start '2026-11-27' -AllDay -Source b)
      ))
    $merged.Count | Should -Be 2
  }
}

Describe 'Get-WbTitleCore' {
  It '<title> has core <want>' -ForEach @(
    @{ title = 'Boulder Ballet presents The Nutcracker'; want = 'The Nutcracker' }
    @{ title = 'The Nutcracker: With Live Music by the Boulder Phil'; want = 'The Nutcracker' }
    @{ title = 'Jo Koy - Koy Meets World Tour'; want = 'Jo Koy' }
    @{ title = 'Comedy Night'; want = 'Comedy Night' }
    @{ title = 'Disney Presents: Frozen Live'; want = 'Frozen Live' }
    @{ title = 'Pre-K Storytime'; want = 'Pre-K Storytime' }
  ) {
    Get-WbTitleCore $title | Should -Be $want
  }
}

Describe 'Test-WbPlaceholderVenue' {
  It '<venue> is a placeholder: <want>' -ForEach @(
    @{ venue = 'Boulder'; want = $true }
    @{ venue = 'Boulder, CO 80303'; want = $true }
    @{ venue = 'Niwot, Colorado'; want = $true }
    @{ venue = 'Various Boulder County locations'; want = $true }
    @{ venue = 'TBA'; want = $true }
    @{ venue = ''; want = $true }
    @{ venue = '350 Kimbark St, Longmont, CO'; want = $false }
    @{ venue = 'Chautauqua Park'; want = $false }
    @{ venue = 'University Memorial Center'; want = $false }
  ) {
    Test-WbPlaceholderVenue $venue 'Boulder' | Should -Be $want
  }
}

Describe 'Merge-WbEvents canceled events' {
  It 'recognizes <title>: <want>' -ForEach @(
    @{ title = 'CANCELED - Play and Learn'; want = $true }
    @{ title = 'CANCELLED Ping-Pong Club'; want = $true }
    @{ title = 'CANCELED-Toddler Storytime'; want = $true }
    @{ title = 'Canceled LEGO Club'; want = $true }
    @{ title = 'Cancel Culture Comedy Hour'; want = $false }
  ) {
    Test-WbCanceledTitle $title | Should -Be $want
  }

  It 'drops a canceled event only with -DropCanceled' {
    $events = @((New-TestEvent -Title 'CANCELED - Play and Learn' -Source a), (New-TestEvent -Title 'Toddler Time' -Start '2026-11-15T10:00:00-07:00' -Source a))
    @(Merge-WbEvents $events).Count | Should -Be 2
    $kept = @(Merge-WbEvents $events -DropCanceled)
    $kept.Count | Should -Be 1
    $kept[0].title | Should -Be 'Toddler Time'
  }

  It 'drops the listing a cancellation from another source matches' {
    $merged = @(Merge-WbEvents @(
        (New-TestEvent -Title 'Play and Learn' -Source mom -Url 'https://mom.test/1')
        (New-TestEvent -Title 'CANCELED - Play and Learn' -Source library -Url 'https://library.test/1')
      ) -Priorities @{ mom = 10; library = 20 } -DropCanceled)
    $merged.Count | Should -Be 0
  }
}