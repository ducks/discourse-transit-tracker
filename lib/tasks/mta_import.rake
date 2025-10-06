# frozen_string_literal: true

desc "Import MTA Subway GTFS data"
task "transit_tracker:import_mta" => :environment do
  puts "Starting MTA GTFS import..."

  service = MtaGtfsService.new
  stats = service.import

  puts "\n✓ MTA import complete!"
  puts "  Routes processed: #{stats[:routes_processed]}"
  puts "  Trips processed: #{stats[:trips_processed]}"
  puts "  Departures created: #{stats[:departures_created]}"
  puts "  Errors: #{stats[:errors]}"
end
