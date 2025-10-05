# frozen_string_literal: true

desc "Clean up old transit departure topics"
task "transit_tracker:cleanup" => :environment do
  puts "Cleaning up old transit departure topics..."

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
