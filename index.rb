require 'date'
require 'erb'
require 'open-uri'
require 'rss'
require 'time'

require 'bundler/inline'

gemfile do
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

venues << Venue.new(:name => 'Bottom of the Hill', :link => 'http://www.bottomofthehill.com') do
  URI.open(URI.join(link, 'RSS.xml'), 'User-Agent' => '') do |rss|
    RSS::Parser.parse(rss).items.group_by(&:link).transform_values do |items|
      items.max_by(&:date)
    end.map do |date, item|
      date = Date.parse(item.link[/\d+/])
      time = item.description.scan(/\d{1,2}(?:\:\d{2})?\s*[ap]m/i).map do |time|
        Time.parse(time, date)
      end.min
      show(
        :time => time,
        :link => item.link,
        :title => item.title.partition(':').last.strip,
        :description => item.description
      )
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
    <% venues.each do |venue| %>
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
