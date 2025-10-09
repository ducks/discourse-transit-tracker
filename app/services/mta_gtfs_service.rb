# frozen_string_literal: true

require "csv"
require "zip"
require "open-uri"
require "tempfile"

class MtaGtfsService
  GTFS_URL = "http://web.mta.info/developers/data/nyct/subway/google_transit.zip"

  # Import MTA GTFS data
  # @return [Hash] Statistics about the import
  def import
    Rails.logger.info "[TransitTracker] Starting MTA GTFS import"

    stats = {
      routes_processed: 0,
      trips_processed: 0,
      departures_created: 0,
      errors: 0
    }

    begin
      # Download and extract GTFS ZIP
      gtfs_data = download_and_extract_gtfs

      # Parse the data
      routes = parse_routes(gtfs_data[:routes])
      stops = parse_stops(gtfs_data[:stops])
      trips = parse_trips(gtfs_data[:trips])

      Rails.logger.info "[TransitTracker] Parsed #{routes.size} routes, #{stops.size} stops, #{trips.size} trips"

      # Create departures for the next 2 hours (memory efficient)
      create_departures_streaming(routes, stops, trips, gtfs_data[:stop_times], stats)

      Rails.logger.info "[TransitTracker] MTA import complete: #{stats}"
    rescue => e
      Rails.logger.error "[TransitTracker] MTA import failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      stats[:errors] += 1
    end

    stats
  end

  private

  def download_and_extract_gtfs
    Rails.logger.info "[TransitTracker] Downloading MTA GTFS from #{GTFS_URL}"

    tempfile = Tempfile.new(["mta_gtfs", ".zip"], binmode: true)

    begin
      # Download the ZIP file
      URI.open(GTFS_URL, "rb") do |zip_file|
        tempfile.write(zip_file.read)
        tempfile.rewind
      end

      # Extract relevant files
      data = {}

      Zip::File.open(tempfile.path) do |zip|
        # Read the CSV files we need
        data[:routes] = read_zip_entry(zip, "routes.txt")
        data[:stops] = read_zip_entry(zip, "stops.txt")
        data[:trips] = read_zip_entry(zip, "trips.txt")
        data[:stop_times] = read_zip_entry(zip, "stop_times.txt")
        data[:calendar] = read_zip_entry(zip, "calendar.txt")
      end

      Rails.logger.info "[TransitTracker] GTFS files extracted successfully"
      data
    ensure
      tempfile.close
      tempfile.unlink
    end
  end

  def read_zip_entry(zip, filename)
    entry = zip.find_entry(filename)
    return nil unless entry
    entry.get_input_stream.read.force_encoding("UTF-8")
  end

  def parse_routes(csv_content)
    return {} if csv_content.nil?

    routes = {}
    CSV.parse(csv_content, headers: true) do |row|
      routes[row["route_id"]] = {
        short_name: row["route_short_name"],
        long_name: row["route_long_name"],
        type: row["route_type"],
        color: row["route_color"]
      }
    end
    routes
  end

  def parse_stops(csv_content)
    return {} if csv_content.nil?

    stops = {}
    CSV.parse(csv_content, headers: true) do |row|
      stops[row["stop_id"]] = {
        name: row["stop_name"],
        code: row["stop_code"],
        lat: row["stop_lat"],
        lon: row["stop_lon"]
      }
    end
    stops
  end

  def parse_trips(csv_content)
    return {} if csv_content.nil?

    trips = {}
    CSV.parse(csv_content, headers: true) do |row|
      trips[row["trip_id"]] = {
        route_id: row["route_id"],
        service_id: row["service_id"],
        headsign: row["trip_headsign"],
        direction: row["direction_id"]
      }
    end
    trips
  end

  # Memory-efficient streaming approach
  def create_departures_streaming(routes, stops, trips, stop_times_csv, stats)
    # Get today's date and time window
    now = Time.zone.now
    today = now.to_date
    time_window_end = now + 2.hours

    Rails.logger.info "[TransitTracker] Filtering trips in time window (#{now} to #{time_window_end})"

    # First pass: Find trips in our time window by checking first stops
    # Keep only trip_id and first departure time to minimize memory
    valid_trips = {}

    Rails.logger.info "[TransitTracker] First pass: identifying trips in time window..."
    CSV.parse(stop_times_csv, headers: true) do |row|
      trip_id = row["trip_id"]
      stop_sequence = row["stop_sequence"].to_i

      # Only look at first stops (sequence 1 or 0)
      next unless stop_sequence <= 1

      departure_time = row["departure_time"]
      next if departure_time.blank?

      dep_time = parse_gtfs_time(today, departure_time)
      next unless dep_time

      # Check if in our time window
      if dep_time >= now && dep_time <= time_window_end
        valid_trips[trip_id] = dep_time
      end
    end

    Rails.logger.info "[TransitTracker] Found #{valid_trips.size} trips in time window"

    # Second pass: Load stop times ONLY for valid trips
    # Process in batches to avoid memory buildup
    Rails.logger.info "[TransitTracker] Second pass: loading stop times for valid trips..."

    stop_times_by_trip = {}
    CSV.parse(stop_times_csv, headers: true) do |row|
      trip_id = row["trip_id"]
      next unless valid_trips.key?(trip_id)

      stop_times_by_trip[trip_id] ||= []
      stop_times_by_trip[trip_id] << {
        trip_id: trip_id,
        stop_id: row["stop_id"],
        stop_sequence: row["stop_sequence"].to_i,
        arrival_time: row["arrival_time"],
        departure_time: row["departure_time"]
      }
    end

    Rails.logger.info "[TransitTracker] Loaded stop times for #{stop_times_by_trip.size} trips"

    # Process trips in batches to avoid memory issues
    batch_size = 50
    processed = 0

    stop_times_by_trip.each_slice(batch_size) do |batch|
      batch.each do |trip_id, trip_stop_times|
        trip_data = trips[trip_id]
        next unless trip_data && trip_data[:route_id]

        route = routes[trip_data[:route_id]]
        next unless route

        next if trip_stop_times.empty?

        # Sort by stop sequence
        trip_stop_times = trip_stop_times.sort_by { |st| st[:stop_sequence] }

        # Get first and last stop
        first_stop = trip_stop_times.first
        last_stop = trip_stop_times.last

        next unless first_stop && last_stop

        origin_stop = stops[first_stop[:stop_id]]
        dest_stop = stops[last_stop[:stop_id]]

        next unless origin_stop && dest_stop

        # Parse times
        dep_time = parse_gtfs_time(today, first_stop[:departure_time])
        arr_time = parse_gtfs_time(today, last_stop[:arrival_time])

        next unless dep_time

        # Skip if train has already departed
        next if dep_time < now

        # Build detailed stops array
        detailed_stops = trip_stop_times.map do |st|
          stop_info = stops[st[:stop_id]]
          next unless stop_info

          {
            stop_id: st[:stop_id],
            stop_name: stop_info[:name],
            stop_code: stop_info[:code],
            lat: stop_info[:lat],
            lon: stop_info[:lon],
            arrival_time: parse_gtfs_time(today, st[:arrival_time])&.iso8601,
            departure_time: parse_gtfs_time(today, st[:departure_time])&.iso8601,
            stop_sequence: st[:stop_sequence]
          }
        end.compact

        # Create the departure record
        departure_data = {
          mode: "metro",
          service_date: today.to_s,
          origin: first_stop[:stop_id],
          origin_name: origin_stop[:name],
          dest: last_stop[:stop_id],
          dest_name: dest_stop[:name],
          dep_sched_at: dep_time,
          dep_est_at: nil,
          arr_sched_at: arr_time,
          arr_est_at: nil,
          platform: nil,
          gate: nil,
          terminal: nil,
          route_short_name: route[:short_name] || route[:long_name],
          route_color: route[:color],
          headsign: trip_data[:headsign] || dest_stop[:name],
          trip_id: trip_id,
          vehicle_id: nil,
          source: "mta",
          stops: detailed_stops
        }

        begin
          topic = TransitLeg.create_or_update(departure_data)

          # Create a detailed schedule post if topic has stops
          if topic && detailed_stops.length > 2
            create_schedule_post(topic, detailed_stops, route, trip_data)
          end

          stats[:departures_created] += 1
        rescue => e
          Rails.logger.error "[TransitTracker] Failed to create departure for trip #{trip_id}: #{e.message}"
          stats[:errors] += 1
        end

        stats[:trips_processed] += 1
        processed += 1
      end

      # Force garbage collection after each batch
      GC.start if processed % batch_size == 0
      Rails.logger.info "[TransitTracker] Processed #{processed}/#{valid_trips.size} trips..."
    end
  end

  def create_schedule_post(topic, stops, route, trip_data)
    # Check if schedule post already exists
    existing_schedule_post = topic.posts.where(user_id: Discourse.system_user.id).where("post_number > 1").first
    return if existing_schedule_post

    schedule_content = build_schedule_content(stops, route, trip_data)

    PostCreator.create!(
      Discourse.system_user,
      topic_id: topic.id,
      raw: schedule_content,
      skip_validations: true,
    )

    Rails.logger.info "[TransitTracker] Created schedule post for topic #{topic.id}"
  rescue => e
    Rails.logger.error "[TransitTracker] Failed to create schedule post: #{e.message}"
  end

  def build_schedule_content(stops, route, trip_data)
    # Build only the dynamic stop rows
    stop_rows = stops.map do |stop|
      arrival = stop[:arrival_time] ? Time.parse(stop[:arrival_time]).strftime("%H:%M") : "—"
      departure = stop[:departure_time] ? Time.parse(stop[:departure_time]).strftime("%H:%M") : "—"
      stop_name = stop[:stop_name] || stop[:stop_id]
      "| #{stop_name} | #{arrival} | #{departure} |"
    end.join("\n")

    # Use heredoc template with interpolated values
    <<~SCHEDULE
      ## Complete Schedule

      **Line:** #{route[:short_name]}
      **Direction:** #{trip_data[:headsign]}

      | Stop | Arrival | Departure |
      |------|---------|-----------|
      #{stop_rows}

      _Schedule times are in UTC. This is the planned schedule and may be subject to delays._
    SCHEDULE
  end

  def parse_gtfs_time(base_date, time_string)
    return nil if time_string.blank?

    # GTFS times can be > 24 hours (e.g., "25:30:00" for 1:30 AM next day)
    hours, minutes, seconds = time_string.split(":").map(&:to_i)

    days_offset = hours / 24
    hours = hours % 24

    time = base_date.to_time.utc.change(hour: hours, min: minutes, sec: seconds)
    time += days_offset.days if days_offset > 0

    time
  rescue => e
    Rails.logger.error "[TransitTracker] Failed to parse GTFS time #{time_string}: #{e.message}"
    nil
  end
end
