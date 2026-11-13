BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Cities.ps1"

  function New-OtherEvent {
    param([string]$Title = 'Holiday Bazaar', [string]$Venue = 'Various Boulder County locations', [string]$Description = '', [string]$City = 'Other', [string]$VenueKey = 'various-boulder-county')
    [pscustomobject]@{ title = $Title; venue = $Venue; venueKey = $VenueKey; city = $City; description = $Description }
  }
}

Describe 'Get-WbCityClue' {
  It 'finds <want> in "<title>" / "<venue>" / "<description>"' -ForEach @(
    @{ title = 'Paella on the Patio'; venue = 'Various Boulder County locations'; description = 'On the plaza at 1303 Pearl St, Boulder, CO 80302'; want = 'Boulder' }
    @{ title = 'Holiday Boutique'; venue = 'louisville, CO'; description = ''; want = 'Louisville' }
    @{ title = 'Craft Fair'; venue = 'Various'; description = 'At the hall, 123 Main St 80501'; want = 'Longmont' }
    @{ title = 'Breakfast with Santa | Lafayette YMCA'; venue = 'Various'; description = ''; want = 'Lafayette' }
    @{ title = 'KidStrong Longmont | Parents Night Out'; venue = 'Various'; description = ''; want = 'Longmont' }
    @{ title = 'Holiday Magic on Main Street (Lyons)'; venue = 'Various'; description = ''; want = 'Lyons' }
    @{ title = 'Tree Lighting'; venue = 'Various'; description = 'Held at the Superior, Colorado town hall'; want = 'Superior' }
    @{ title = 'Veterans Breakfast | Dickens Opera House'; venue = 'Various'; description = ''; want = 'Longmont' }
    @{ title = 'Old Town Lights'; venue = 'Various'; description = 'Join us in downtown Broomfield for the lights'; want = 'Broomfield' }
    @{ title = 'Movie Night'; venue = 'Various'; description = 'A family movie at the North Boulder YMCA'; want = 'Boulder' }
    @{ title = 'Winter Carnival'; venue = 'Various'; description = 'Gunbarrel Center, 6525 Gunbarrel Ave 80301'; want = 'Boulder' }
    @{ title = 'Tree Lighting'; venue = 'Various'; description = 'First Street, 80466'; want = 'Nederland' }
  ) {
    Get-WbCityClue (New-OtherEvent -Title $title -Venue $venue -Description $description) | Should -Be $want
  }

  It 'returns nothing for <case>' -ForEach @(
    @{ case = 'no clue at all'; title = 'Home Depot Kids Workshop'; description = 'Workshops run the first Saturday of each month' }
    @{ case = 'two cities at the same strength'; title = 'Holiday Lights Tour'; description = 'Buses leave from Boulder and Longmont' }
    @{ case = 'a company named after a city'; title = 'Free Christmas Movie'; description = 'The movies Boulder Weekly once provided for our community' }
    @{ case = 'a bare ambiguous word'; title = 'Star Party'; description = 'Superior views of every star in the sky with Lyons and the Lake Erie astronomy club' }
  ) {
    Get-WbCityClue (New-OtherEvent -Title $title -Description $description) | Should -BeNullOrEmpty
  }

  It 'uses a venue that other events place in one city' {
    $map = @{ 'garden-center' = 'Louisville' }
    Get-WbCityClue (New-OtherEvent -Title 'Wreath Workshop' -Venue 'GC' -VenueKey 'garden-center') -VenueCities $map | Should -Be 'Louisville'
  }

  It 'prefers a ZIP code over a city named in the title' {
    Get-WbCityClue (New-OtherEvent -Title 'Boulder Bazaar' -Description 'At the fairgrounds, Longmont CO 80501') | Should -Be 'Longmont'
  }
}

Describe 'Get-WbVenueCities' {
  It 'leaves out a placeholder venue that also appears as Other' {
    $map = Get-WbVenueCities @(
      (New-OtherEvent -City 'Boulder')
      (New-OtherEvent -City 'Other')
      (New-OtherEvent -VenueKey 'macky-auditorium' -City 'Boulder')
    )
    $map.ContainsKey('various-boulder-county') | Should -BeFalse
    $map['macky-auditorium'] | Should -Be 'Boulder'
  }

  It 'leaves out a venue placed in two cities' {
    $map = Get-WbVenueCities @((New-OtherEvent -VenueKey 'ymca' -City 'Boulder'), (New-OtherEvent -VenueKey 'ymca' -City 'Lafayette'))
    $map.ContainsKey('ymca') | Should -BeFalse
  }
}

Describe 'Resolve-WbOtherCity' {
  It 'changes only events stored as Other and counts them' {
    $events = @(
      (New-OtherEvent -Title 'Hawaiian Bingo | Lafayette YMCA')
      (New-OtherEvent -Title 'Home Depot Kids Workshop')
      (New-OtherEvent -Title 'Longmont Tree Lighting' -City 'Boulder' -VenueKey 'city-hall')
    )
    Resolve-WbOtherCity $events | Should -Be 1
    $events.city | Should -Be @('Lafayette', 'Other', 'Boulder')
  }
}

Describe 'Resolve-WbTitleVenue' {
  BeforeAll {
    function New-Placed {
      param([string]$Title, [string]$Venue, [string]$City, [string]$Source = 'venue-site')
      New-WbEvent -Title $Title -Start '2026-11-12T10:00:00-07:00' -Venue $Venue -City $City -Category 'community-civic' `
        -Url "https://$Source.test/e" -Sources @(@{ name = $Source; url = "https://$Source.test/e"; fetchedAt = '2026-11-01T10:00:00Z' })
    }
    function New-Placeholder {
      param([string]$Title)
      New-WbEvent -Title $Title -Start '2026-11-12T10:00:00-07:00' -Venue 'Various Boulder County locations' -VenueKey 'various-boulder-county' `
        -City 'Other' -Category 'community-civic' -Url 'https://mom.test/e' -Sources @(@{ name = 'mom'; url = 'https://mom.test/e'; fetchedAt = '2026-11-01T10:00:00Z' })
    }
  }

  It 'gives a placeholder-venue event the venue its title names, when another event places it' {
    $museum = New-Placed '$3 Thursdays' 'Museum of Boulder' 'Boulder'
    $mom = New-Placeholder '$3 Admission Day at Museum of Boulder'
    $events = @($museum, $mom, (New-Placeholder 'Holiday Bazaar'))
    Resolve-WbTitleVenue $events | Should -Be 1
    $mom.venue | Should -Be 'Museum of Boulder'
    $mom.venueKey | Should -Be 'museum-of-boulder'
    $mom.city | Should -Be 'Boulder'
  }

  It 'rebuilds the id and size as New-WbEvent would for that venue' {
    $mom = New-Placeholder '$3 Admission Day at Museum of Boulder'
    $null = Resolve-WbTitleVenue @((New-Placed 'Museum Day' 'Museum of Boulder' 'Boulder'), $mom)
    $want = New-WbEvent -Title '$3 Admission Day at Museum of Boulder' -Start '2026-11-12T10:00:00-07:00' -Venue 'Museum of Boulder' -City 'Boulder' -Category 'community-civic' `
      -Url 'https://mom.test/e' -Sources @(@{ name = 'mom'; url = 'https://mom.test/e'; fetchedAt = '2026-11-01T10:00:00Z' })
    $mom.id | Should -Be $want.id
    $mom.size | Should -Be $want.size
  }

  It 'reads "at the" followed by the venue too' {
    $mom = New-Placeholder 'Holiday Market at the Boulder Bookstore'
    $null = Resolve-WbTitleVenue @((New-Placed 'Craft Fair' 'Boulder Bookstore' 'Boulder'), $mom)
    $mom.venueKey | Should -Be 'boulder-bookstore'
  }

  It 'leaves an event whose named venue no other event places' {
    $mom = New-Placeholder 'Cookies with Santa at Boulder County Festival of Trees'
    Resolve-WbTitleVenue @($mom) | Should -Be 0
    $mom.venueKey | Should -Be 'various-boulder-county'
    $mom.city | Should -Be 'Other'
  }

  It 'leaves an event that already has a real venue' {
    $show = New-Placed 'Lights at Museum of Boulder' 'Boulder Public Library' 'Boulder'
    Resolve-WbTitleVenue @((New-Placed 'Museum Day' 'Museum of Boulder' 'Boulder'), $show) | Should -Be 0
    $show.venueKey | Should -Be 'boulder-public-library'
  }

  It 'reads a venue after "|", drops it from the title, and knows places from place-cities.json' {
    $mom = New-Placeholder '1st Sunday Brunch | Dickens Opera House'
    Resolve-WbTitleVenue @($mom) | Should -Be 1
    $mom.title | Should -Be '1st Sunday Brunch'
    $mom.venue | Should -Be 'Dickens Opera House'
    $mom.venueKey | Should -Be 'dickens-opera-house'
    $mom.city | Should -Be 'Longmont'
  }

  It 'reads a venue after "@" or a spaced dash' {
    $at = New-Placeholder 'Story Time @ Museum of Boulder'
    $dash = New-Placeholder 'Fossil Talk - Museum of Boulder'
    $null = Resolve-WbTitleVenue @((New-Placed 'Museum Day' 'Museum of Boulder' 'Boulder'), $at, $dash)
    $at.title | Should -Be 'Story Time'
    $dash.title | Should -Be 'Fossil Talk'
    $dash.venueKey | Should -Be 'museum-of-boulder'
  }

  It 'rebuilds the id from the shortened title' {
    $mom = New-Placeholder '1st Sunday Brunch | Dickens Opera House'
    $null = Resolve-WbTitleVenue @($mom)
    $mom.id | Should -Be (Get-WbEventId '1st Sunday Brunch' $mom.start 'dickens-opera-house')
  }

  It 'leaves text after "|" that is not a known venue' {
    $mom = New-Placeholder 'Holiday Fun | Dog Winter Photo Sessions'
    Resolve-WbTitleVenue @($mom) | Should -Be 0
    $mom.title | Should -Be 'Holiday Fun | Dog Winter Photo Sessions'
  }

  It 'does not take a city name as a venue' {
    $mom = New-Placeholder 'Veterans Day Celebration | Lafayette'
    Resolve-WbTitleVenue @((New-Placed 'Parade' 'Lafayette' 'Lafayette'), $mom) | Should -Be 0
    $mom.title | Should -Be 'Veterans Day Celebration | Lafayette'
  }

  It 'ignores a venue seen in more than one city' {
    $mom = New-Placeholder 'Story Time at Main Library'
    $events = @((New-Placed 'A' 'Main Library' 'Boulder'), (New-Placed 'B' 'Main Library' 'Broomfield'), $mom)
    Resolve-WbTitleVenue $events | Should -Be 0
  }
}
