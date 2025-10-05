# frozen_string_literal: true

class TransitUpdaterService
  def self.update_all
    puts "[TransitTracker] Update called"
    Rails.logger.info "[TransitTracker] Update called"

    if !SiteSetting.transit_tracker_enabled
      puts "[TransitTracker] Plugin not enabled"
      return
    end

    puts "[TransitTracker] Starting update cycle"
    Rails.logger.info "[TransitTracker] Starting update cycle"
    all_departures = []

    # Fetch from Golemio (Prague transit)
    if SiteSetting.transit_tracker_golemio_api_token.present?
      golemio = GolemioService.new
      golemio_departures = golemio.fetch_departures
      all_departures.concat(golemio_departures)
      Rails.logger.info "[TransitTracker] Fetched #{golemio_departures.count} departures from Golemio"
    end

    # Fetch from AviationStack (flights)
    if SiteSetting.transit_tracker_aviationstack_api_key.present?
      puts "[TransitTracker] Calling AviationStack API..."
      aviationstack = AviationstackService.new
      flight_departures = aviationstack.fetch_departures
      all_departures.concat(flight_departures)
      puts "[TransitTracker] Fetched #{flight_departures.count} departures from AviationStack"
      Rails.logger.info "[TransitTracker] Fetched #{flight_departures.count} departures from AviationStack"
    end

    puts "[TransitTracker] Processing #{all_departures.count} total departures"
    Rails.logger.info "[TransitTracker] Processing #{all_departures.count} total departures"

    all_departures.each_with_index do |departure, idx|
      puts "[TransitTracker] Processing #{idx+1}/#{all_departures.count}: #{departure[:route_short_name]} to #{departure[:dest_name]} at #{departure[:dep_sched_at]}"
      process_departure(departure)
    end

    puts "[TransitTracker] Update cycle complete"
    Rails.logger.info "[TransitTracker] Update cycle complete"
  end

  def self.process_departure(departure)
    TransitLeg.create_or_update(departure)
  rescue => e
    Rails.logger.error "[TransitTracker] Failed to process departure: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
