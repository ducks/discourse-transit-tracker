# frozen_string_literal: true

desc "Import Amtrak GTFS data"
task "transit_tracker:import_amtrak" => :environment do
  puts "Starting Amtrak GTFS import..."

  service = AmtrakGtfsService.new
  stats = service.import

  puts "\n✓ Amtrak import complete!"
  puts "  Routes processed: #{stats[:routes_processed]}"
  puts "  Trips processed: #{stats[:trips_processed]}"
  puts "  Departures created: #{stats[:departures_created]}"
  puts "  Errors: #{stats[:errors]}"
end
