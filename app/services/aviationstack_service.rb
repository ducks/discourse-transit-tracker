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
      flight_status = flight["flight_status"]

      next unless departure_info && arrival_info && flight_info

      # Handle code-share flights: use operating carrier as the natural key
      codeshared = flight_info["codeshared"]
      if codeshared.present?
        # This is a marketing carrier selling seats on another airline's flight
        # Use the operating flight as trip_id so all code-shares merge
        operating_flight = codeshared["flight_iata"] || codeshared["flight_icao"]
        trip_id = "#{operating_flight}-#{departure_info['scheduled']}"
        marketing_flight = flight_info["iata"] || flight_info["icao"]

        Rails.logger.info "[TransitTracker] Code-share detected: #{marketing_flight} operated by #{operating_flight}"
      else
        # Regular flight: use this flight's number
        trip_id = "#{flight_info['iata']}-#{departure_info['scheduled']}"
        marketing_flight = flight_info["iata"] || flight_info["icao"]
      end

      # Map API status to our status tags (API is source of truth)
      status = case flight_status
      when "cancelled" then "canceled"  # Convert British → American spelling
      when "active" then "departed"     # In the air
      when "landed" then "departed"     # Already arrived
      when "scheduled" then nil         # Use timing-based inference
      else nil                          # Unknown status, use timing-based inference
      end

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
        route_short_name: marketing_flight,
        headsign: arrival_info["airport"],
        trip_id: trip_id,
        vehicle_id: flight["aircraft"]&.dig("registration"),
        source: "aviationstack",
        stops: [],
        status: status,  # API status (if provided)
        # Extra flight details for the details post
        flight_details: {
          airline_name: flight["airline"]&.dig("name"),
          airline_iata: flight["airline"]&.dig("iata"),
          flight_status: flight_status,
          departure_delay: departure_info["delay"],
          departure_actual: parse_time(departure_info["actual"]),
          arrival_gate: arrival_info["gate"],
          arrival_baggage: arrival_info["baggage"],
          arrival_actual: parse_time(arrival_info["actual"]),
          aircraft_registration: flight["aircraft"]&.dig("registration"),
          codeshare_info: codeshared,  # Store the full codeshare object
        },
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
