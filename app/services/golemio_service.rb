# frozen_string_literal: true

class GolemioService
  BASE_URL = "https://api.golemio.cz/v2"

  def initialize
    @api_token = SiteSetting.transit_tracker_golemio_api_token
  end

  # Fetch departures for configured stops
  # @return [Array<Hash>] Array of departure data
  def fetch_departures
    stops = parse_stops
    return [] if stops.empty?

    all_departures = []

    stops.each do |stop_id|
      begin
        departures = fetch_departures_for_stop(stop_id)
        all_departures.concat(departures)
      rescue => e
        Rails.logger.error "[TransitTracker] Error fetching departures for stop #{stop_id}: #{e.message}"
      end
    end

    all_departures
  end

  private

  def parse_stops
    stops_setting = SiteSetting.transit_tracker_monitored_stops
    return [] if stops_setting.blank?

    stops_setting.split(",").map(&:strip).reject(&:blank?)
  end

  def fetch_departures_for_stop(stop_id)
    url = "#{BASE_URL}/pid/departureboards"
    minutes = SiteSetting.transit_tracker_time_window_minutes

    response =
      Faraday.get(url) do |req|
        req.headers["X-Access-Token"] = @api_token
        req.headers["Content-Type"] = "application/json"
        req.params["ids"] = stop_id
        req.params["minutesBefore"] = 0
        req.params["minutesAfter"] = minutes
        req.params["limit"] = 50
      end

    return [] unless response.success?

    data = JSON.parse(response.body)
    parse_departures(data)
  rescue => e
    Rails.logger.error "[TransitTracker] API request failed: #{e.message}"
    []
  end

  def parse_departures(data)
    departures = []

    # Get stop info
    stops = data["stops"] || []
    stop_map = stops.index_by { |s| s["stop_id"] }

    data["departures"]&.each do |departure_data|
      route = departure_data["route"]
      trip = departure_data["trip"]
      timestamps = departure_data["departure_timestamp"]

      next unless route && trip && timestamps

      # Get stop info (may not always be present)
      stop_id = departure_data["stop_id"]
      stop_info = stop_map[stop_id]

      departure = {
        mode: map_mode(route["type"]),
        service_date: Date.today.to_s,
        origin: stop_id,
        origin_name: stop_info&.dig("stop_name") || stop_id,
        dest: trip["headsign"],
        dest_name: trip["headsign"],
        dep_sched_at: parse_time(timestamps["scheduled"]),
        dep_est_at: parse_time(timestamps["predicted"]),
        arr_sched_at: nil, # Not provided by API
        arr_est_at: nil,
        platform: departure_data["platform_code"],
        gate: nil,
        terminal: nil,
        route_short_name: route["short_name"],
        headsign: trip["headsign"],
        trip_id: trip["id"],
        vehicle_id: departure_data["vehicle_registration_number"],
        source: "golemio",
        stops: [], # Could be enhanced with full trip data
      }

      departures << departure
    end

    departures
  end

  def parse_time(timestamp)
    return nil if timestamp.blank?
    Time.zone.parse(timestamp)
  rescue => e
    Rails.logger.error "[TransitTracker] Failed to parse timestamp #{timestamp}: #{e.message}"
    nil
  end

  def map_mode(route_type)
    # GTFS route_type mapping
    case route_type
    when 0
      "tram"
    when 1
      "metro"
    when 3
      "bus"
    when 2
      "train"
    else
      "bus"
    end
  end
end
