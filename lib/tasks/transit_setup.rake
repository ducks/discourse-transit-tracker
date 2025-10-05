# frozen_string_literal: true

desc "Setup Transit Tracker categories and tags"
task "transit_tracker:setup" => :environment do
  puts "Setting up Transit Tracker..."

  # Create categories
  planes_cat = create_category("Planes", "Track flights and air travel")
  trains_cat = create_category("Trains", "Track train departures and arrivals")
  transit_cat = create_category("Public Transit", "Track buses, trams, and metro")

  # Update settings
  SiteSetting.transit_tracker_planes_category_id = planes_cat.id
  SiteSetting.transit_tracker_trains_category_id = trains_cat.id
  SiteSetting.transit_tracker_public_transit_category_id = transit_cat.id

  puts "✓ Categories created and configured"

  # Create tag groups
  create_tag_group(
    "Transit Mode",
    %w[flight train tram bus metro],
    "Transportation mode",
  )

  create_tag_group(
    "Transit Status",
    %w[status:scheduled status:boarding status:departed status:delayed status:arrived status:canceled status:diverted],
    "Current status of the transit leg",
  )

  puts "✓ Tag groups created"
  puts ""
  puts "Transit Tracker setup complete!"
  puts ""
  puts "Next steps:"
  puts "1. Enable the plugin at /admin/site_settings/category/plugins?filter=transit"
  puts "2. Set your Golemio API token: transit_tracker_golemio_api_token"
  puts "3. Configure monitored stops (comma-separated stop IDs)"
  puts "4. The updater job will run every #{SiteSetting.transit_tracker_polling_interval_minutes} minutes"
  puts ""
  puts "Category IDs:"
  puts "  Planes: #{planes_cat.id}"
  puts "  Trains: #{trains_cat.id}"
  puts "  Public Transit: #{transit_cat.id}"
end

def create_category(name, description)
  category = Category.find_by(name: name)

  if category
    puts "  Category '#{name}' already exists (ID: #{category.id})"
    return category
  end

  category =
    Category.create!(
      name: name,
      description: description,
      user: Discourse.system_user,
      read_restricted: false,
    )

  # Make categories read-only for regular users
  category.set_permissions(trust_level_0: :readonly)
  category.save!

  puts "  Created category '#{name}' (ID: #{category.id})"
  category
end

def create_tag_group(name, tags, description)
  tag_group = TagGroup.find_by(name: name)

  if tag_group
    puts "  Tag group '#{name}' already exists"
    return tag_group
  end

  # Create tags if they don't exist
  tag_objects = tags.map do |tag_name|
    Tag.find_or_create_by(name: tag_name) do |t|
      t.name = tag_name
    end
  end

  tag_group =
    TagGroup.create!(
      name: name,
      tag_names: tags,
      one_per_topic: name == "Transit Status",
    )

  puts "  Created tag group '#{name}' with #{tags.count} tags"
  tag_group
end
