BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/CityLookup.ps1"

  $script:now = [DateTimeOffset]::Parse('2026-11-07T08:00:00Z')

  # A local parenting blog style event page: no venue, a Website link, and a footer that names Boulder.
  function New-EventPage([string]$Website, [string]$Venue) {
    $venueBlock = if ($Venue) { "<div class=`"tribe-events-meta-group tribe-events-meta-group-venue`"><dd class=`"tribe-venue`">$Venue</dd></div>" } else { '' }
    $site = if ($Website) { "<span class=`"tribe-events-event-url tribe-events-meta-value`"> <a href=`"$Website`" target=`"_self`" rel=`"external`">$Website</a> </span>" } else { '' }
    "<html><body><div class=`"tribe-events-meta-group tribe-events-meta-group-details`">$site</div>$venueBlock<footer>Boulder, CO Guide to Parks</footer></body></html>"
  }

  function New-TestEvent([string]$Url = 'https://mom.test/event/journal/', [string]$City = 'Other') {
    [pscustomobject]@{ id = 'e1'; title = 'Nature Journaling'; start = '2026-11-13T13:30:00-07:00'; city = $City; url = $Url; sources = @(@{ name = 'boulder-mom'; url = $Url }) }
  }

  # Pages by URL. A missing URL answers 404. Every request is recorded in $script:requests.
  function New-Fetcher([hashtable]$Pages) {
    $log = [Collections.Generic.List[string]]::new()
    $script:requests = $log
    {
      param([string]$Url)
      $log.Add($Url)
      if ($Pages.ContainsKey($Url)) { return $Pages[$Url] }
      throw "HTTP 404 from $Url"
    }.GetNewClosure()
  }
}

Describe 'Find-WbAddressCity' {
  It 'finds <want> in <html>' -ForEach @(
    @{ html = '<p>7275 Ridge Rd suite 100, Niwot, Colorado 80544</p>'; want = 'Niwot' }
    @{ html = '<p>1 DesCombes Dr, Broomfield, CO 80020</p>'; want = 'Broomfield' }
    @{ html = '<script type="application/ld+json">{"@type":"Event","name":"x","startDate":"2026-11-13","location":{"address":{"addressLocality":"Longmont","addressRegion":"CO"}}}</script>'; want = 'Longmont' }
    @{ html = '<script type="application/ld+json">{"@type":"Event","name":"x","startDate":"2026-11-13","location":{"address":{"addressLocality":"Gunbarrel","addressRegion":"CO"}}}</script>'; want = 'Boulder' }
  ) {
    Find-WbAddressCity $html | Should -Be $want
  }

  It 'gives up when the page names two cities' {
    Find-WbAddressCity '<p>Boulder, CO 80302</p><p>Broomfield, CO 80020</p>' | Should -BeNullOrEmpty
  }

  It 'ignores the site''s navigation and page header' {
    $page = '<header><nav><ul><li><a href="/g">Guide to Moving to Boulder, CO</a></li></ul></nav></header>' +
      '<nav>Visit Longmont, CO</nav><main><div>7275 Ridge Rd, Niwot, CO 80544</div></main>'
    Find-WbAddressCity $page | Should -Be 'Niwot'
  }

  It 'needs a state after the city, so prose does not count' {
    Find-WbAddressCity '<p>Fun for all of Boulder and Longmont</p>' | Should -BeNullOrEmpty
  }
}

Describe 'Get-WbEventWebsite' {
  It 'reads the Website link from an Events Calendar page' {
    Get-WbEventWebsite (New-EventPage -Website 'https://library.test/cal/#/events/1') | Should -Be 'https://library.test/cal/#/events/1'
  }
}

Describe 'Invoke-WbCityLookup' {
  It 'follows the Website link to the organizer, ignoring the listing site footer' {
    $fetch = New-Fetcher @{
      'https://mom.test/robots.txt'     = ''
      'https://mom.test/event/journal/' = (New-EventPage -Website 'https://library.test/cal/#/events/1')
      'https://library.test/robots.txt' = ''
      'https://library.test/cal/'       = '<footer>7275 Ridge Rd, Niwot, Colorado 80544</footer>'
    }
    $event = New-TestEvent
    $result = Invoke-WbCityLookup @($event) -State @{} -Now $now -Fetch $fetch -MinDelaySeconds 0
    $event.city | Should -Be 'Niwot'
    $result.Found | Should -Be 1
    $result.State['https://mom.test/event/journal/'].city | Should -Be 'Niwot'
    $result.State['https://mom.test/event/journal/'].website | Should -Be 'https://library.test/cal/#/events/1'
  }

  It 'uses the venue block on the event page when it has one' {
    $fetch = New-Fetcher @{
      'https://mom.test/robots.txt'     = ''
      'https://mom.test/event/journal/' = (New-EventPage -Venue 'Louisville Public Library, 951 Spruce St, Louisville, CO 80027')
    }
    $event = New-TestEvent
    $null = Invoke-WbCityLookup @($event) -State @{} -Now $now -Fetch $fetch -MinDelaySeconds 0
    $event.city | Should -Be 'Louisville'
  }

  It 'falls back to the home page when the linked page names no city' {
    $fetch = New-Fetcher @{
      'https://mom.test/robots.txt'     = ''
      'https://mom.test/event/journal/' = (New-EventPage -Website 'https://cider.test/events')
      'https://cider.test/robots.txt'   = ''
      'https://cider.test/events'       = '<p>No address here</p>'
      'https://cider.test/'             = '<p>1501 Lee Hill Dr, Boulder, CO 80304</p>'
    }
    $event = New-TestEvent
    $null = Invoke-WbCityLookup @($event) -State @{} -Now $now -Fetch $fetch -MinDelaySeconds 0
    $event.city | Should -Be 'Boulder'
  }

  It 'never requests a site on the skip list, such as Facebook' {
    $fetch = New-Fetcher @{
      'https://mom.test/robots.txt'     = ''
      'https://mom.test/event/journal/' = (New-EventPage -Website 'https://www.facebook.com/share/p/1Fb6/')
    }
    $event = New-TestEvent
    $null = Invoke-WbCityLookup @($event) -State @{} -Now $now -Fetch $fetch -MinDelaySeconds 0
    $event.city | Should -Be 'Other'
    $requests | Where-Object { $_ -like '*facebook*' } | Should -BeNullOrEmpty
  }

  It 'never requests a page robots.txt disallows' {
    $fetch = New-Fetcher @{
      'https://mom.test/robots.txt'     = ''
      'https://mom.test/event/journal/' = (New-EventPage -Website 'https://private.test/e/1')
      'https://private.test/robots.txt' = "User-agent: *`nDisallow: /"
    }
    $event = New-TestEvent
    $null = Invoke-WbCityLookup @($event) -State @{} -Now $now -Fetch $fetch -MinDelaySeconds 0
    $requests | Should -Not -Contain 'https://private.test/e/1'
    $requests | Should -Not -Contain 'https://private.test/'
  }

  It 'applies a remembered city without a request, and looks again after 30 days' {
    $state = @{ 'https://mom.test/event/journal/' = [ordered]@{ city = 'Niwot'; checkedAt = '2026-11-01T08:00:00Z' } }
    $fetch = New-Fetcher @{}
    $event = New-TestEvent
    $null = Invoke-WbCityLookup @($event) -State $state -Now $now -Fetch $fetch -MinDelaySeconds 0
    $event.city | Should -Be 'Niwot'
    $requests.Count | Should -Be 0

    $later = $now.AddDays(31)
    $null = Invoke-WbCityLookup @((New-TestEvent)) -State $state -Now $later -Fetch $fetch -MinDelaySeconds 0
    $requests | Should -Contain 'https://mom.test/event/journal/'
  }

  It 'waits 7 days before trying again on a page that named no city' {
    $state = @{ 'https://mom.test/event/journal/' = [ordered]@{ checkedAt = '2026-11-03T08:00:00Z' } }
    $fetch = New-Fetcher @{}
    $null = Invoke-WbCityLookup @((New-TestEvent)) -State $state -Now $now -Fetch $fetch -MinDelaySeconds 0
    $requests.Count | Should -Be 0
  }

  It 'leaves events that already have a city alone' {
    $fetch = New-Fetcher @{}
    $event = New-TestEvent -City 'Broomfield'
    $null = Invoke-WbCityLookup @($event) -State @{} -Now $now -Fetch $fetch -MinDelaySeconds 0
    $requests.Count | Should -Be 0
  }

  It 'makes no requests with a budget of 0, but still applies what it knows' {
    $state = @{ 'https://mom.test/event/journal/' = [ordered]@{ city = 'Nederland'; checkedAt = '2026-10-01T08:00:00Z' } }
    $fetch = New-Fetcher @{}
    $event = New-TestEvent
    $null = Invoke-WbCityLookup @($event) -State $state -Now $now -Fetch $fetch -MinDelaySeconds 0 -BudgetSeconds 0
    $event.city | Should -Be 'Nederland'
    $requests.Count | Should -Be 0
  }

  It 'forgets pages no event has used for 30 days' {
    $state = @{ 'https://mom.test/gone/' = [ordered]@{ city = 'Boulder'; checkedAt = '2026-09-01T08:00:00Z' } }
    $result = Invoke-WbCityLookup @() -State $state -Now $now -Fetch (New-Fetcher @{}) -MinDelaySeconds 0
    $result.State.ContainsKey('https://mom.test/gone/') | Should -BeFalse
  }
}
