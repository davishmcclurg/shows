require 'date'
require 'erb'
require 'open-uri'
require 'rss'

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
end

Show = Struct.new(:time, :link, :title, :description, :venue, :keyword_init => true)

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
  URI.open(URI.join(link, 'RSS.xml'), 'User-Agent' => '') do |rss|
    RSS::Parser.parse(rss).items.group_by(&:link).transform_values do |items|
      items.max_by(&:date)
    end.map do |date, item|
      date = Date.parse(item.link[/\d+/])
      time = item.description.scan(/\d{1,2}(?:\:\d{2})?\s*[ap]m/i).map do |time|
        Time.parse(time, date)
      end.min
      time ||= Time.parse('12:00pm', date)
      show(
        :time => time,
        :link => item.link,
        :title => item.title.partition(':').last.strip,
        :description => item.description
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
      time = Time.parse(article.css('div.event-info p:not(.organizer)').first.text)
      organizer = article.css('div.event-info p.organizer').text
      price = article.css('div.buy p.ticket-price').text
      link = article.css('div.buy div a.events-ticket-button').attr('href').value

      # Flaccid attempt to cast yearless dates into the future for dec->jan
      # rollover. We could probably add a helper for this.
      time += (60 * 60 * 24 * 365) if time.month < today.month

      description = [organizer, price].reject(&:empty?).join(' - ')

      show(time: time, link: link, title: title, description: description)
    end
  end
end

shows = venues.flat_map(&:shows)
shows.select! { |show| show.time >= today.to_time }
shows.sort_by!(&:time)

include ERB::Util

def normalize(text)
  fragment = Nokogiri::HTML.fragment(text)
  fragment.css('br').each { |node| node.replace(' / ') }
  h(fragment.text.strip)
end

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
                <%= show.time.strftime('%a, %b %-d') %>
                <br>
                <%= show.time.strftime('%l:%M%P') %>
              </p>
            </td>
            <td valign="top">
              <p>
                <strong><a href="<%= h(show.link) %>"><%= normalize(show.title) %></a></strong>
                <br>
                <%= normalize(show.description) %>
              </p>
            </td>
            <td nowrap valign="top">
              <p>
                <a href="<%= h(show.venue.link) %>"><%= normalize(show.venue.name) %></a>
              </p>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </body>
  </html>
ERB
