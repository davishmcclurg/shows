require 'base64'
require 'date'
require 'erb'
require 'json'
require 'open-uri'
require 'rss'

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
end

Show = Struct.new(:time, :link, :title, :description, :venue, :keyword_init => true) do
  def ical_link
    'data:text/calendar;base64,' +
    Base64.urlsafe_encode64(
      [
        ['BEGIN', 'VCALENDAR'],
        ['VERSION', '2.0'],
        ['BEGIN', 'VEVENT'],
        ['URL', link],
        ['DTSTART', ical_time(time)],
        ['DTEND', ical_time(time + (3600 * 3))],
        ['DTSTAMP', ical_time(time)],
        ['SUMMARY', title],
        ['DESCRIPTION', description&.gsub("\n", '\\n')],
        ['LOCATION', venue.name],
        ['END', 'VEVENT'],
        ['END', 'VCALENDAR']
      ].map { |e| e.join(':') }.join("\n")
    )
  end

  private

  # https://icalendar.org/iCalendar-RFC-5545/3-3-5-date-time.html
  def ical_time(time)
    time.utc.strftime('%Y%m%dT%H%M%SZ')
  end
end

Venue = Struct.new(:name, :link, :shows, :keyword_init => true) do
  def initialize(*, &block)
    super
    self.shows = instance_eval(&block) if block_given?
  end

  def show(**kwargs)
    Show.new(:venue => self, **kwargs)
  end
end

today = Date.today
venues = []

venues << Venue.new(:name => 'Cornerstone (Berkeley)', :link => 'https://cornerstoneberkeley.com/music-venue/') do
  URI.open(link) do |html|
    Nokogiri(html).css('article.list-view-item').map do |article|
      title = article.css('h1.headliners,p.supports').map(&:content).reject(&:empty?).join(', ')
      next if title =~ /passes/i # skip links to multi-day passes

      date = Date.parse(article.css('span.dates').text)

      # Handle yearless dates through the december->january rollover
      date += 365 if date.month < today.month

      time = Time.parse(article.css('span.start').text, date)
      show(
        :title => title,
        :time => time,
        :link => article.css('h1.headliners').css('a').attr('href').value,
      )
    end.compact
  end
end

venues << Venue.new(:name => 'Bottom of the Hill', :link => 'http://www.bottomofthehill.com') do
  URI.open(URI.join(link, 'RSS.xml'), 'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:104.0) Gecko/20100101 Firefox/104.0') do |rss|
    RSS::Parser.parse(rss).items.group_by(&:link).transform_values do |items|
      items.max_by(&:date)
    end.map do |date, item|
      date = Date.parse(item.link[/\d+/])
      time = item.description.scan(/\d{1,2}(?:\:\d{2})?\s*[ap]m/i).map do |time|
        Time.parse(time, date)
      end.min
      time ||= Time.parse('12:00pm', date)
      fragment = Nokogiri::HTML.fragment(item.description)
      fragment.css('br').each { |node| node.replace(' / ') }
      show(
        :time => time,
        :link => item.link,
        :title => item.title.partition(':').last.strip,
        :description => fragment.text.strip
      )
    end
  end
end

venues << Venue.new(:name => 'Brick and Mortar', :link => 'https://www.brickandmortarmusic.com') do
  URI.open(link) do |html|
    previous_date = today
    Nokogiri(html).css('.tw-event-name-container').flat_map do |event_name_container|
      row = event_name_container.parent
      href = event_name_container.css('.tw-name a').attr('href')

      dates_times_and_links = event_name_container.css('.tw-event-time').map do |event_time|
        [
          row.css('.tw-date-time .tw-event-date').text,
          event_time.text,
          href.value
        ]
      end

      dates_times_and_links += row.css('.tw-sequential-dates').map do |sequential_date|
        [
          sequential_date.css('.tw-event-date').text,
          sequential_date.css('.tw-event-time').text,
          (sequential_date.css('.tw-more-info a').attr('href') || href).value
        ]
      end

      dates_times_and_links.map do |date_text, time_text, link|
        date = Date.new(today.year, *date_text.split('.').map(&:to_i))
        date = date.next_year if date < previous_date
        previous_date = date
        show(
          :time => Time.parse(time_text, date),
          :link => link,
          :title => event_name_container.css('.tw-name').text,
          :description => event_name_container.css('.tw-name-presenting').text
        )
      end
    end
  end
end

venues << Venue.new(:name => 'Rickshaw Stop', :link => 'https://rickshawstop.com/') do
  URI.open(link) do |html|
    Nokogiri(html).css('article.event-card').map do |article|
      title = article.css('div.event-info h1 a').text
      time = Time.parse(article.css('div.event-info .detail_event_date').first.text)
      supporting_talent = article.css('div.event-info .detail_supporting_talent').text
      organizer = article.css('div.event-info p.organizer').text
      price = article.css('div.buy p.ticket-price').text
      link = article.css('div.buy div a.events-ticket-button').attr('href').value

      # Flaccid attempt to cast yearless dates into the future for dec->jan
      # rollover. We could probably add a helper for this.
      time += (60 * 60 * 24 * 365) if time.month < today.month

      description = [supporting_talent, organizer, price].reject(&:empty?).join(' - ')

      show(time: time, link: link, title: title, description: description)
    end
  end
end

venues << Venue.new(:name => 'DNA Lounge', :link => 'https://www.dnalounge.com') do
  # Regex to dig the calendar link out of the description
  link_regex = Regexp.new(/https:\/\/www.dnalounge.com\/calendar\/\d{4}\/[\d\w\-]+\.html/i)

  URI.open(URI.join(link, 'calendar/dnalounge.rss')) do |xml|
    Nokogiri::XML(xml).css('item').map do |item|
      description = item.css('description').text

      show(
        time: Time.parse(item.css('pubDate').text),
        link: description[link_regex] || item.css('guid').text,
        title: item.css('title').text,
        description: description.length > 1000 ? description[0...999] + "…" : description
      )
    end
  end
end

venues << Venue.new(:name => 'Kilowatt', :link => 'https://kilowattbar.com/') do
  URI.open(URI.join(link, 'events-1')) do |html|
    # We need to pull the api key from a script tag inside an iframe. Nokogiri
    # doesn't parse javascript, so a greasy regex will have to do for now.
    api_key = Nokogiri::HTML(html).css('iframe').attr('srcdoc').text.match(/"apiKey":"(\w+)"/)[1]

    uri = URI.parse('https://events-api.dice.fm/v1/events?page[size]=24&types=linkout,event&filter[venues][]=Kilowatt')
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json'
      request['x-api-key'] = api_key

      http.request(request)
    end

    JSON.parse(response.body).fetch('data').map do |event|
      show(
        time: Time.parse(event.fetch('date')).getlocal,
        link: event.fetch('url'),
        title: event.fetch('name'),
        description: event.fetch('description')
      )
    end
  end
end

venues << Venue.new(:name => 'Knockout', :link => 'https://theknockoutsf.com') do
  URI.open(URI.join(link, 'events/feed')) do |xml|
    RSS::Parser.parse(xml).items.map do |item|
      description = Nokogiri::HTML(item.content_encoded).text

      # Workaround for the occasional empty title
      title = item.title
      title = description.split('•').first if title.empty?

      next if title =~ /(karaoke|bingo)/i

      show(
        time: item.pubDate.getlocal,
        link: item.link,
        title: title,
        description: description
      )
    end.compact
  end
end

shows = venues.flat_map(&:shows)
shows.select! { |show| show.time >= today.to_time }
shows.sort_by!(&:time)

include ERB::Util

ERB.new(<<~ERB).run
  <!doctype html>
  <html>
  <head>
    <title>Shows</title>
  </head>
  <body>
    <% venues.sort_by(&:name).each do |venue| %>
      <style>
        #venue-<%= h(venue.object_id) %>:not(:checked) ~ table tr[data-venue="<%= h(venue.object_id) %>"] {
          display: none;
        }
      </style>
      <input type="checkbox" id="venue-<%= h(venue.object_id) %>" checked>
      <label for="venue-<%= h(venue.object_id) %>"><%= h(venue.name) %></label>
    <% end %>
    <table border="1" cellpadding="8">
      <thead>
        <tr>
          <th>Date</th>
          <th>Show</th>
          <th>Venue</th>
        </tr>
      </thead>
      <tbody>
        <% shows.each do |show| %>
          <tr data-venue="<%= h(show.venue.object_id) %>">
            <td nowrap valign="top">
              <p>
                <a href="<%= h(show.ical_link) %>">
                  <%= show.time.strftime('%a, %b %-d') %>
                  <br>
                  <%= show.time.strftime('%l:%M%P') %>
                </a>
              </p>
            </td>
            <td valign="top">
              <p>
                <strong><a href="<%= h(show.link) %>"><%= h(show.title) %></a></strong>
                <br>
                <%= h(show.description) %>
              </p>
            </td>
            <td nowrap valign="top">
              <p>
                <a href="<%= h(show.venue.link) %>"><%= h(show.venue.name) %></a>
              </p>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </body>
  </html>
ERB
