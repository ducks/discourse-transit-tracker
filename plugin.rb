# frozen_string_literal: true

# name: discourse-transit-tracker
# about: Turn Discourse into a lightweight live departures hub for transit tracking
# version: 0.1.0
# authors: Discourse
# url: https://github.com/discourse/discourse-transit-tracker

enabled_site_setting :transit_tracker_enabled

register_asset "stylesheets/transit-board.scss"

module ::DiscourseTransitTracker
  PLUGIN_NAME ||= "discourse-transit-tracker"
end

require_relative "lib/discourse_transit_tracker/engine"

after_initialize do
  require_relative "app/models/transit_leg"
  require_relative "app/services/golemio_service"
  require_relative "app/services/aviationstack_service"
  require_relative "app/services/transit_updater_service"
  require_relative "app/controllers/transit_board_controller"
  require_relative "app/controllers/transit_proxy_controller"
  require_relative "app/controllers/discourse_transit_tracker/board_controller"
  require_relative "app/jobs/scheduled/update_transit_departures"

  # Register custom topic fields
  register_topic_custom_field_type("transit_service_date", :string)
  register_topic_custom_field_type("transit_origin", :string)
  register_topic_custom_field_type("transit_origin_name", :string)
  register_topic_custom_field_type("transit_dest", :string)
  register_topic_custom_field_type("transit_dest_name", :string)
  register_topic_custom_field_type("transit_dep_sched_at", :datetime)
  register_topic_custom_field_type("transit_dep_est_at", :datetime)
  register_topic_custom_field_type("transit_arr_sched_at", :datetime)
  register_topic_custom_field_type("transit_arr_est_at", :datetime)
  register_topic_custom_field_type("transit_platform", :string)
  register_topic_custom_field_type("transit_gate", :string)
  register_topic_custom_field_type("transit_terminal", :string)
  register_topic_custom_field_type("transit_route_short_name", :string)
  register_topic_custom_field_type("transit_route_color", :string)
  register_topic_custom_field_type("transit_headsign", :string)
  register_topic_custom_field_type("transit_trip_id", :string)
  register_topic_custom_field_type("transit_vehicle_id", :string)
  register_topic_custom_field_type("transit_source", :string)
  register_topic_custom_field_type("transit_stops", :json)

  # Add preload for topic list
  add_preloaded_topic_list_custom_field("transit_dep_est_at")
  add_preloaded_topic_list_custom_field("transit_dep_sched_at")
  add_preloaded_topic_list_custom_field("transit_route_short_name")
  add_preloaded_topic_list_custom_field("transit_headsign")
  add_preloaded_topic_list_custom_field("transit_platform")
end
