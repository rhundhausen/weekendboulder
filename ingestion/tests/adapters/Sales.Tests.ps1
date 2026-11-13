BeforeAll {
  $script:adapter = Join-Path $PSScriptRoot '..' '..' 'scripts' 'adapters' 'sales.ps1'
  $script:fetchedAt = '2026-11-09T07:00:00Z'

  function New-SaleSource {
    param([string]$Mode, [string]$Name, [string]$Url, [string]$Venue)
    [pscustomobject]@{
      name = $Name; displayName = $Venue; adapter = 'sales'; salesMode = $Mode; url = $Url
      category = 'auctions-estate-sales'; city = 'Boulder'; venue = $Venue; venueKey = $Name
    }
  }

  # Runs the adapter on one response and returns the events, keeping the drop counts it reports.
  function Invoke-Sales {
    param([pscustomobject]$Source, [string]$Text)
    $output = & $adapter -Source $Source -FetchedAt $fetchedAt -Response @($Text) -Verbose 4>&1
    $script:summary = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object Message) -join "`n"
    @($output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
  }
}

Describe 'sales adapter, ics mode' {
  BeforeAll {
    $source = New-SaleSource 'ics' 'front-range-auction' 'https://auction.test/events/list/?ical=1' 'Front Range Auction'
    $feed = @'
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261111
DTEND;VALUE=DATE:20261112
UID:1@auction.test
SUMMARY:431 W 10th Ave\, Broomfield\, CO
DESCRIPTION:431 W 10th Ave\, Broomfield\, CO\nAbsolute Real Estate Auction\nWednesday\, November 11th\, 2026 at 2 pm\nLOCATION: 431 W 10th Ave\, Broomfield\, CO 80020\nCall Dusty (303)555-0100 with any questions.
URL:https://auction.test/event/431-w-10th-ave-broomfield-co/
CATEGORIES:Real Estate,Real Estate Auction
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261111
DTEND;VALUE=DATE:20261112
UID:2@auction.test
SUMMARY:Brewer Incredible Online Estate Auction
DESCRIPTION:November 11th\, 2026 at 5 pm\n 431 W 10th Ave\, Broomfield\, CO\nClick Here to Bid
URL:https://auction.test/event/brewer/
CATEGORIES:Estate Auction,Online
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261114
UID:3@auction.test
SUMMARY:Farm Equipment Auction
DESCRIPTION:Saturday\, November 14th\, 2026 at 10 am\nLOCATION: 123 Main St\, Berthoud\, CO 80513
URL:https://auction.test/event/farm/
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261121
UID:4@auction.test
SUMMARY:Coin Auction
DESCRIPTION:Saturday November 21st at 1 pm. Place to be announced.
URL:https://auction.test/event/coins/
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261118
UID:5@auction.test
SUMMARY:999 Hover St\, Longmont\, CO
DESCRIPTION:999 Hover St\, Longmont\, CO\nReal Estate Auction\nWednesday November 18th\, 2026 at 2 pm\nLOCATION: 999 Hover St\, Longmont\, CO 80501
URL:https://auction.test/event/999-hover-st/
CATEGORIES:Commercial,Real Estate
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261121
UID:6@auction.test
SUMMARY:Smith Family Estate Auction
DESCRIPTION:Saturday\, November 21st\, 2026 at 10 am\nLOCATION: 123 Elm St\, Broomfield\, CO 80020\nTools\, furniture\, and collectibles.
URL:https://auction.test/event/smith-estate/
CATEGORIES:Estate Auction
END:VEVENT
END:VCALENDAR
'@
    $script:auctionFeed = $feed
    $script:kept = Invoke-Sales $source $feed
    $script:auctionSummary = $script:summary
  }

  It 'keeps live real estate auctions, with their time, when the source sets keepRealEstate' {
    $live = $source | Select-Object *
    $live | Add-Member -NotePropertyName keepRealEstate -NotePropertyValue $true
    $events = Invoke-Sales $live $auctionFeed
    @($events.title) | Should -Be @('431 W 10th Ave, Broomfield, CO', '999 Hover St, Longmont, CO', 'Smith Family Estate Auction')
    $events[0].start | Should -Be '2026-11-11T14:00:00-07:00'
    $events[0].city | Should -Be 'Broomfield'
    $events[1].city | Should -Be 'Longmont'
    # Online bidding is still dropped by the in-person rule.
    $events.title | Should -Not -Contain 'Brewer Incredible Online Estate Auction'
    $summary | Should -Match '0 dropped as real estate'
  }

  It 'keeps only the live estate auction, dropping real estate auctions' {
    @($kept.title) | Should -Be @('Smith Family Estate Auction')
    $kept[0].city | Should -Be 'Broomfield'
  }

  It 'reads the start time from the description' {
    $kept[0].start | Should -Be '2026-11-21T10:00:00-07:00'
    $kept[0].allDay | Should -BeFalse
  }

  It 'stores only the title, company, city, times, and link' {
    $kept[0].venue | Should -Be 'Front Range Auction'
    $kept[0].url | Should -Be 'https://auction.test/event/smith-estate/'
    $kept[0].category | Should -Be 'auctions-estate-sales'
    $kept[0].PSObject.Properties.Name | Should -Not -Contain 'description'
    # The link is the site's own event page, whose slug can hold the street; nothing else may.
    ($kept | Select-Object -Property * -ExcludeProperty url, sources | ConvertTo-Json -Depth 5) | Should -Not -Match 'Elm St|Tools|555-0100'
  }

  It 'reports what each rule dropped' {
    $auctionSummary | Should -Match 'kept 1'
    $auctionSummary | Should -Match '2 dropped by the in-person rule'
    $auctionSummary | Should -Match '2 dropped as real estate'
    $auctionSummary | Should -Match '1 dropped by the city filter'
  }
}

Describe 'Get-WbSaleVerdict' {
  BeforeAll { . "$PSScriptRoot/../../scripts/lib/Sales.ps1" }

  It 'drops anything that says online, in any case' {
    Get-WbSaleVerdict -Title 'Estate Auction' -Text 'Bid ONLINE now' -HasPlace $true -City 'Boulder' | Should -Be 'in-person'
  }

  It 'drops a sale with no place' {
    Get-WbSaleVerdict -Title 'Estate Auction' -Text '' -HasPlace $false -City $null | Should -Be 'in-person'
  }

  It 'drops a place outside the covered cities' {
    Get-WbSaleVerdict -Title 'Estate Auction' -Text '' -HasPlace $true -City $null | Should -Be 'city'
  }

  It 'drops a real estate auction, marked by the site or named in the title' {
    Get-WbSaleVerdict -Title 'Home and Shop' -Text '' -HasPlace $true -City 'Broomfield' -RealEstate $true | Should -Be 'real-estate'
    Get-WbSaleVerdict -Title 'Absolute Real Estate Auction' -Text '' -HasPlace $true -City 'Broomfield' | Should -Be 'real-estate'
  }

  It 'keeps an estate sale whose text mentions real estate' {
    Get-WbSaleVerdict -Title 'Estate Sale' -Text 'Ask us about real estate services' -HasPlace $true -City 'Boulder' | Should -Be 'keep'
  }

  It 'keeps an in-person sale in a covered city' {
    Get-WbSaleVerdict -Title 'Estate Auction' -Text '' -HasPlace $true -City 'Longmont' | Should -Be 'keep'
  }
}
