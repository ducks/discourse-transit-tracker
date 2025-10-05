# frozen_string_literal: true

desc "Reprocess existing transit topics to merge code-shares"
task "transit_tracker:reprocess" => :environment do
  puts "Reprocessing transit topics to merge code-shares..."

  category_ids = [
    SiteSetting.transit_tracker_planes_category_id,
    SiteSetting.transit_tracker_trains_category_id,
    SiteSetting.transit_tracker_public_transit_category_id,
  ].compact.reject(&:zero?)

  if category_ids.empty?
    puts "No transit categories configured."
    exit
  end

  topics = Topic
    .where(category_id: category_ids)
    .where(deleted_at: nil)
    .where(
      "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = 'transit_trip_id')"
    )
    .order(:created_at)

  puts "Found #{topics.count} transit topics"

  # Group flights by time/gate/destination
  flight_groups = {}

  topics.each do |topic|
    mode = topic.custom_fields["transit_route_short_name"]&.include?("/") ? "flight" :
           (topic.tags.pluck(:name).include?("flight") ? "flight" : "other")

    next if mode != "flight"

    dep_time = topic.custom_fields["transit_dep_sched_at"]
    gate = topic.custom_fields["transit_gate"]
    dest = topic.custom_fields["transit_dest"]

    key = "#{dep_time}|#{gate}|#{dest}"
    flight_groups[key] ||= []
    flight_groups[key] << topic
  end

  merged_count = 0

  flight_groups.each do |key, group_topics|
    next if group_topics.size < 2

    puts "\nFound #{group_topics.size} flights to merge:"
    flight_numbers = []

    # Keep the first topic, merge others into it
    primary = group_topics.first

    group_topics.each do |topic|
      flight_num = topic.custom_fields["transit_route_short_name"]
      flight_numbers << flight_num if flight_num.present?
      puts "  - #{flight_num} (Topic #{topic.id})"
    end

    # Update primary topic with all flight numbers
    merged_flight_numbers = flight_numbers.join(" / ")
    primary.custom_fields["transit_route_short_name"] = merged_flight_numbers
    primary.title = "#{merged_flight_numbers} to #{primary.custom_fields['transit_headsign']} at #{Time.parse(primary.custom_fields['transit_dep_sched_at']).strftime('%H:%M')}"
    primary.save_custom_fields(true)
    primary.save!

    puts "  → Merged into: #{merged_flight_numbers} (Topic #{primary.id})"

    # Delete the other topics
    group_topics[1..-1].each do |topic|
      topic.trash!(Discourse.system_user)
    end

    merged_count += group_topics.size - 1
  end

  puts "\n✓ Merged #{merged_count} duplicate code-share flights"
end
