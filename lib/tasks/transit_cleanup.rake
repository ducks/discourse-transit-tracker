# frozen_string_literal: true

desc "Clean up departed transit topics (departed more than 1 hour ago)"
task "transit_tracker:cleanup" => :environment do
  puts "Cleaning up departed transit topics..."

  category_ids = [
    SiteSetting.transit_tracker_planes_category_id,
    SiteSetting.transit_tracker_trains_category_id,
    SiteSetting.transit_tracker_public_transit_category_id,
  ].compact.reject(&:zero?)

  if category_ids.empty?
    puts "No transit categories configured. Run transit_tracker:setup first."
    exit
  end

  cutoff = 1.hour.ago
  deleted_count = 0

  topics = Topic
    .where(category_id: category_ids)
    .where(deleted_at: nil)
    .where(
      "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = 'transit_trip_id')"
    )

  puts "Checking #{topics.count} transit topics..."

  topics.find_each do |topic|
    dep_time_str = topic.custom_fields["transit_dep_sched_at"] ||
                   topic.custom_fields["transit_dep_est_at"]

    next unless dep_time_str

    begin
      dep_time = dep_time_str.is_a?(String) ? Time.parse(dep_time_str) : dep_time_str

      if dep_time < cutoff
        topic.trash!(Discourse.system_user)
        deleted_count += 1
        puts "  ✓ Trashed: #{topic.title} (departed at #{dep_time.strftime('%H:%M')})"
      end
    rescue => e
      puts "  ✗ Failed to parse time for topic #{topic.id}: #{e.message}"
    end
  end

  puts ""
  puts "✓ Cleanup complete: #{deleted_count} departed topics trashed"
end

desc "Clean up ALL transit topics (use with caution)"
task "transit_tracker:cleanup_all" => :environment do
  puts "Cleaning up ALL transit departure topics..."

  category_ids = [
    SiteSetting.transit_tracker_planes_category_id,
    SiteSetting.transit_tracker_trains_category_id,
    SiteSetting.transit_tracker_public_transit_category_id,
  ].compact.reject(&:zero?)

  if category_ids.empty?
    puts "No transit categories configured. Run transit_tracker:setup first."
    exit
  end

  topics = Topic
    .where(category_id: category_ids)
    .where(deleted_at: nil)
    .where(
      "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = 'transit_trip_id')"
    )

  count = topics.count
  puts "Found #{count} transit topics to delete"

  if count > 0
    print "Are you sure you want to delete all #{count} transit topics? (y/n): "
    response = STDIN.gets.chomp.downcase

    if response == "y" || response == "yes"
      topics.each do |topic|
        topic.trash!(Discourse.system_user)
      end
      puts "✓ Deleted #{count} transit topics"
    else
      puts "Cancelled"
    end
  else
    puts "No topics to delete"
  end
end
