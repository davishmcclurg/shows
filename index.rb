require 'base64'
require 'date'
require 'digest'
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
    dtstart = ical_time(time)
    ics = [
      ['BEGIN', 'VCALENDAR'],
      ['PRODID', '+//IDN davishmcclurg.github.io//NONSGML shows//EN'],
      ['VERSION', '2.0'],
      ['BEGIN', 'VEVENT'],
      ['UID', "#{digest}@davishmcclurg.github.io"],
      ['DTSTAMP', dtstart],
      ['URL', link],
      ['DTSTART', dtstart],
      ['DTEND', ical_time(time + (3600 * 3))],
      ['SUMMARY', title],
      ['DESCRIPTION', description],
      ['LOCATION', venue.name],
      ['END', 'VEVENT'],
      ['END', 'VCALENDAR']
    ].map do |property, value|
      # https://www.rfc-editor.org/rfc/rfc5545#section-3.1
      lines = ["#{property}:"]
      value.to_s.strip.gsub("\n", '\\n').each_grapheme_cluster do |grapheme|
        lines << ' ' if (lines.last.bytesize + grapheme.bytesize) > 75
        lines.last << grapheme
      end
      lines.join("\r\n")
    end.join("\r\n")
    "data:text/calendar;base64,#{Base64.strict_encode64(ics)}"
  end

  def digest
    Digest::SHA2.hexdigest("#{time}:#{link}:#{title}:#{description}:#{venue.name}")
  end

  private

  # https://www.rfc-editor.org/rfc/rfc5545#section-3.3.5
  def ical_time(time)
    time.getutc.strftime('%Y%m%dT%H%M%SZ')
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

def seetickets_parser(html)
  Nokogiri(html).css('.seetickets-list-events:not(#just-announced-events-list) .event-info-block').map do |event|
    title = event.css('.title').text

    next if title =~ /private (event|party)/i

    date = Date.parse(event.css('.date').text)
    # Handle yearless dates through the december->january rollover
    date += 365 if date.month < Date.today.month
    time = Time.parse(event.css('.see-doortime, .see-showtime').first.text, date)

    show(
      time: time,
      link: event.css('.title a').attr('href').value,
      title: title,
      description: event.css('.subtitle, .doortime-showtime, .ages, .price, .ages-price').map(&:text).reject(&:empty?).join('. ')
    )
  end.compact
end

def truncate(text, len = 1000)
  text.length > len ? text[0...999].chomp(' ') + "…" : text
end

today = Date.today
venues = []

venues << Venue.new(:name => 'Cornerstone (Berkeley)', :link => 'https://cornerstoneberkeley.com/events') do
  URI.open(link) do |html|
    Nokogiri(html).css('div.shows-wrapper div.w-dyn-item').map do |item|
      show(
        :title => item.css('div.event-name').text,
        :description => item.css('div#event-desc p').map(&:text).join(' '),
        :time => Time.parse(item.css('div.time-2:not(:empty)').first.text, Date.parse(item.css('div.date-2').text)),
        :link => item.css('a.tickets').attr('href').value
      )
    end
  end
end

venues << Venue.new(:name => 'Bottom of the Hill', :link => 'http://www.bottomofthehill.com') do
  URI.open(URI.join(link, 'RSS.xml'), 'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:104.0) Gecko/20100101 Firefox/104.0') do |rss|
    RSS::Parser.parse(rss).items.group_by(&:link).transform_values do |items|
      items.max_by(&:date)
    end.map do |date, item|
      backup_date, _delimiter, title = item.title.partition(':').map(&:strip)
      date = Date.parse(item.link[/\d+/]) rescue Date.parse(backup_date)
      time = item.description.scan(/\d{1,2}(?:\:\d{2})?\s*[ap]m/i).map do |time|
        Time.parse(time, date)
      end.min
      time ||= Time.parse('12:00pm', date)
      fragment = Nokogiri::HTML.fragment(item.description)
      fragment.css('br').each { |node| node.replace(' / ') }
      show(
        :time => time,
        :link => item.link,
        :title => title,
        :description => fragment.text.strip
      )
    end
  end
end

venues << Venue.new(:name => 'Brick and Mortar', :link => 'https://www.brickandmortarmusic.com') do
  URI.open(link, :ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE) do |html|
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
    seetickets_parser(html)
  end
end

venues << Venue.new(:name => 'DNA Lounge', :link => 'https://www.dnalounge.com') do
  # Regex to dig the calendar link out of the description
  link_regex = /https:\/\/www.dnalounge.com\/calendar\/\d{4}\/[\d\w\-]+\.html/i
  title_regex = /\A(#{Date::ABBR_MONTHNAMES.compact.join('|')}) \d+ \((#{Date::ABBR_DAYNAMES.join('|')})\): /i

  URI.open(URI.join(link, 'calendar/dnalounge.rss')) do |xml|
    Nokogiri::XML(xml).css('item').map do |item|
      description = item.css('description').text
      title = item.css('title').text.gsub(title_regex, '')

      show(
        time: Time.parse(item.css('pubDate').text),
        link: description[link_regex] || item.css('guid').text,
        title: title,
        description: description
      )
    end
  end
end

venues << Venue.new(:name => 'Kilowatt', :link => 'https://kilowattbar.com/') do
  URI.open(URI.join(link, 'events')) do |html|
    # We need to pull the api key from a script tag inside an iframe. Nokogiri
    # doesn't parse javascript, so a greasy regex will have to do for now.
    api_key = Nokogiri::HTML(html).css('div.sqs-block-content script').text.match(/"apiKey":"(\w+)"/)[1]

    uri = URI.parse('https://events-api.dice.fm/v1/events?page[size]=24&types=linkout,event&filter[venues][]=Kilowatt')
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json'
      request['x-api-key'] = api_key

      http.request(request)
    end

    JSON.parse(response.body).fetch('data').map do |event|
      title = event.fetch('name')
      next if title =~ /karaoke/i

      show(
        time: Time.parse(event.fetch('date')).getlocal,
        link: event.fetch('url'),
        title: title,
        description: event.fetch('description')
      )
    end.compact
  end
end

venues << Venue.new(:name => 'Knockout', :link => 'https://theknockoutsf.com') do
  [today, today>>1].map do |date|
    date.strftime('%m-%Y')
  end.flat_map do |month|
    URI.open(URI.join(link, "/api/open/GetItemsByMonth?month=#{month}&collectionId=668dcda020574371451c8e12")) do |json|
      JSON.parse(json.read).map do |item|
        title = item['title']
        next if title =~ /(karaoke|bingo|trivia)/i

        show(
          time: Time.at(item['startDate'] / 1000),
          link: URI.join(link, item['fullUrl']),
          title: title,
          description: Nokogiri::HTML(item['excerpt']).text
        )
      end.compact
    end
  end
end

venues << Venue.new(:name => 'The Chapel', :link => 'https://thechapelsf.com/') do
  URI.open(URI.join(link, 'music/')) do |html|
    seetickets_parser(html)
  end
end

shows = venues.flat_map(&:shows)
shows.select! { |show| show.time >= today.to_time }
shows.sort_by! { |show| [show.time, show.title] }

include ERB::Util

File.write('index.html', ERB.new(<<~ERB).result)
  <!doctype html>
  <html>
  <head>
    <title>Shows</title>
  </head>
  <body>
    <script>
      function uncheckOtherVenues(id) {
        var selector = 'input[type="checkbox"]:not(#venue-' + id + ')';
        var checked = !document.querySelector(selector + ':checked');
        document.querySelectorAll(selector).forEach(input => input.checked = checked);
        document.getElementById('venue-' + id).checked = true;
      }
    </script>
    <% venues.sort_by(&:name).each do |venue| %>
      <style>
        #venue-<%= h(venue.object_id) %>:not(:checked) ~ table tr[data-venue="<%= h(venue.object_id) %>"] {
          display: none;
        }
      </style>
      <input type="checkbox" id="venue-<%= h(venue.object_id) %>" checked ondblclick="uncheckOtherVenues(<%= h(venue.object_id) %>)">
      <label for="venue-<%= h(venue.object_id) %>" ondblclick="uncheckOtherVenues(<%= h(venue.object_id) %>)"><%= h(venue.name) %></label>
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
                <a href="<%= h(show.ical_link) %>" download="<%= h(show.digest) %>.ics">
                  <%= show.time.strftime('%a, %b %-d') %>
                  <br>
                  <%= show.time.strftime('%-l:%M%P') %>
                </a>
              </p>
            </td>
            <td valign="top">
              <p>
                <strong><a href="<%= h(show.link) %>"><%= h(show.title) %></a></strong>
                <br>
                <%= h(truncate(show.description)) %>
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

script = ['Hello, you\'re listening to today\'s shows.']
shows.select { |show| show.time.to_date == today }.each do |show|
  script << "At #{show.time.strftime('%-l:%M%P')} #{show.venue.name} is showing: #{show.title}."
end
File.write('today.txt', script.join(' '))
