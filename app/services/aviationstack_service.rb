# frozen_string_literal: true

class AviationstackService
  BASE_URL = "http://api.aviationstack.com/v1"

  def initialize
    @api_key = SiteSetting.transit_tracker_aviationstack_api_key
  end

  # Fetch departures for configured airports
  # @return [Array<Hash>] Array of departure data
  def fetch_departures
    airports = parse_airports
    puts "[TransitTracker] Monitored airports: #{airports.inspect}"

    if airports.empty?
      puts "[TransitTracker] No airports configured!"
      return []
    end

    all_departures = []

    airports.each do |airport_code|
      begin
        puts "[TransitTracker] Fetching for airport: #{airport_code}"
        departures = fetch_departures_for_airport(airport_code)
        puts "[TransitTracker] Got #{departures.count} flights from #{airport_code}"
        all_departures.concat(departures)
      rescue => e
        puts "[TransitTracker] Error: #{e.message}"
        Rails.logger.error "[TransitTracker] Error fetching flights for #{airport_code}: #{e.message}"
      end
    end

    all_departures
  end

  private

  def parse_airports
    airports_setting = SiteSetting.transit_tracker_monitored_airports
    return [] if airports_setting.blank?

    airports_setting.split(",").map(&:strip).reject(&:blank?)
  end

  def fetch_departures_for_airport(airport_code)
    url = "#{BASE_URL}/flights"

    response =
      Faraday.get(url) do |req|
        req.params["access_key"] = @api_key
        req.params["dep_iata"] = airport_code
        req.params["limit"] = 50
      end

    if !response.success?
      Rails.logger.error "[TransitTracker] AviationStack API returned status #{response.status}: #{response.body}"
      return []
    end

    data = JSON.parse(response.body)
    flight_count = data["data"]&.count || 0
    Rails.logger.info "[TransitTracker] AviationStack returned #{flight_count} flights for #{airport_code}"

    if flight_count == 0
      Rails.logger.info "[TransitTracker] API response: #{data.inspect}"
    end

    parse_departures(data)
  rescue => e
    Rails.logger.error "[TransitTracker] API request failed: #{e.message}"
    []
  end

  def parse_departures(data)
    departures = []

    data["data"]&.each do |flight|
      departure_info = flight["departure"]
      arrival_info = flight["arrival"]
      flight_info = flight["flight"]

      next unless departure_info && arrival_info && flight_info

      departure = {
        mode: "flight",
        service_date: parse_date(departure_info["scheduled"]),
        origin: departure_info["iata"],
        origin_name: departure_info["airport"],
        dest: arrival_info["iata"],
        dest_name: arrival_info["airport"],
        dep_sched_at: parse_time(departure_info["scheduled"]),
        dep_est_at: parse_time(departure_info["estimated"]),
        arr_sched_at: parse_time(arrival_info["scheduled"]),
        arr_est_at: parse_time(arrival_info["estimated"]),
        platform: nil,
        gate: departure_info["gate"],
        terminal: departure_info["terminal"],
        route_short_name: flight_info["iata"] || flight_info["icao"],
        headsign: arrival_info["airport"],
        trip_id: "#{flight_info['iata']}-#{departure_info['scheduled']}",
        vehicle_id: flight["aircraft"]&.dig("registration"),
        source: "aviationstack",
        stops: [],
      }

      departures << departure
    end

    departures
  end

  def parse_date(timestamp)
    return Date.today.to_s if timestamp.blank?
    Date.parse(timestamp).to_s
  rescue => e
    Rails.logger.error "[TransitTracker] Failed to parse date #{timestamp}: #{e.message}"
    Date.today.to_s
  end

  def parse_time(timestamp)
    return nil if timestamp.blank?
    Time.zone.parse(timestamp)
  rescue => e
    Rails.logger.error "[TransitTracker] Failed to parse timestamp #{timestamp}: #{e.message}"
    nil
  end
end
