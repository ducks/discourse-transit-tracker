# frozen_string_literal: true

class TransitLeg
  # Wrapper model for Topic with transit custom fields

  attr_accessor :topic

  def initialize(topic)
    @topic = topic
  end

  def self.find_by_natural_key(trip_id, service_date)
    Topic
      .where(
        "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = ? AND value = ?)",
        "transit_trip_id",
        trip_id,
      )
      .where(
        "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = ? AND value = ?)",
        "transit_service_date",
        service_date,
      )
      .first
  end

  def self.find_by_codeshare(attributes)
    return nil if attributes[:mode] != "flight"

    # For flights, check if there's an existing flight with same time/gate/destination
    dep_time = attributes[:dep_sched_at]&.iso8601
    return nil if !dep_time

    Rails.logger.info "[TransitTracker] Looking for code-share: gate=#{attributes[:gate]}, dest=#{attributes[:dest]}, time=#{dep_time}"

    topic = Topic
      .where(
        "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = ? AND value = ?)",
        "transit_service_date",
        attributes[:service_date],
      )
      .where(
        "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = ? AND value = ?)",
        "transit_dep_sched_at",
        dep_time,
      )
      .where(
        "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = ? AND value = ?)",
        "transit_dest",
        attributes[:dest],
      )
      .first

    # Match if gate is the same OR both are nil (for flights without gate info)
    if topic
      existing_gate = topic.custom_fields["transit_gate"]
      if attributes[:gate].present? && existing_gate.present?
        return topic if attributes[:gate] == existing_gate
        return nil
      elsif attributes[:gate].blank? && existing_gate.blank?
        return topic
      end
    end

    nil
  end

  def self.create_or_update(attributes)
    trip_id = attributes[:trip_id]
    service_date = attributes[:service_date]

    # First check for exact match by trip_id
    topic = find_by_natural_key(trip_id, service_date)
    is_new = topic.nil?

    # If no exact match, check for code-share flight
    if !topic && attributes[:mode] == "flight"
      puts "[TransitTracker] No exact match for #{attributes[:route_short_name]}, checking for code-share..."
      topic = find_by_codeshare(attributes)
      if topic
        puts "[TransitTracker] Found code-share match! Topic ID: #{topic.id}"
        is_new = false
      else
        puts "[TransitTracker] No code-share match found, will create new topic"
      end
    end

    if topic && !is_new
      update_topic(topic, attributes)
    else
      create_topic(attributes)
    end
  end

  def self.create_topic(attributes)
    category_id = determine_category(attributes[:mode])
    return unless category_id

    topic =
      Topic.create!(
        title: build_title(attributes),
        user: Discourse.system_user,
        category_id: category_id,
        custom_fields: build_custom_fields(attributes),
      )

    # Create first post with structured data
    PostCreator.create!(
      Discourse.system_user,
      topic_id: topic.id,
      raw: build_post_content(attributes),
      skip_validations: true,
    )

    # Create details post for flights (similar to schedule post for trains)
    if attributes[:mode] == "flight" && attributes[:flight_details].present?
      create_flight_details_post(topic, attributes)
    end

    # Apply tags
    apply_tags(topic, attributes)

    topic
  end

  def self.update_topic(topic, attributes)
    old_status = determine_status(topic)

    # Merge flight numbers for code-share flights
    if attributes[:mode] == "flight"
      existing_flights = topic.custom_fields["transit_route_short_name"] || ""
      flight_numbers = existing_flights.split("/").map(&:strip).reject(&:blank?)
      new_flight = attributes[:route_short_name]

      if !flight_numbers.include?(new_flight)
        flight_numbers << new_flight
        merged = flight_numbers.join(" / ")
        Rails.logger.info "[TransitTracker] Code-share merge: #{existing_flights} + #{new_flight} = #{merged}"
        attributes[:route_short_name] = merged
      else
        Rails.logger.info "[TransitTracker] Flight #{new_flight} already in code-share group"
      end
    end

    topic.custom_fields.merge!(build_custom_fields(attributes))
    topic.save_custom_fields(true)

    new_status = determine_status_from_attributes(attributes)

    # Update tags
    apply_tags(topic, attributes)

    # Post update if status changed significantly
    if status_changed_significantly?(old_status, new_status)
      post_status_update(topic, old_status, new_status, attributes)
    end

    topic
  end

  def self.create_flight_details_post(topic, attributes)
    # Check if details post already exists
    existing_details_post = topic.posts.where(user_id: Discourse.system_user.id).where("post_number > 1").first
    return if existing_details_post

    details_content = build_flight_details_content(attributes)
    PostCreator.create!(
      Discourse.system_user,
      topic_id: topic.id,
      raw: details_content,
      skip_validations: true,
    )
  end

  def self.build_flight_details_content(attributes)
    details = attributes[:flight_details]
    return "" unless details

    content = "## Flight Details\n\n"

    # Airline info
    if details[:airline_name].present?
      airline_code = details[:airline_iata] ? " (#{details[:airline_iata]})" : ""
      content += "**Airline:** #{details[:airline_name]}#{airline_code}\n"
    end

    # Status
    if details[:flight_status].present?
      content += "**Status:** #{details[:flight_status].capitalize}\n"
    end

    content += "\n### Departure - #{attributes[:origin_name]} (#{attributes[:origin]})\n"
    content += "- **Gate:** #{attributes[:gate] || 'TBA'}\n" if attributes[:gate].present? || true
    content += "- **Terminal:** #{attributes[:terminal]}\n" if attributes[:terminal].present?
    content += "- **Scheduled:** #{attributes[:dep_sched_at]&.strftime('%H:%M UTC')}\n"
    content += "- **Estimated:** #{attributes[:dep_est_at]&.strftime('%H:%M UTC')}\n"

    if details[:departure_delay].present? && details[:departure_delay].to_i > 0
      content += "- **Delay:** #{details[:departure_delay]} minutes\n"
    end

    if details[:departure_actual].present?
      content += "- **Actual Departure:** #{details[:departure_actual].strftime('%H:%M UTC')}\n"
    end

    content += "\n### Arrival - #{attributes[:dest_name]} (#{attributes[:dest]})\n"
    content += "- **Gate:** #{details[:arrival_gate] || 'TBA'}\n" if details[:arrival_gate].present? || true
    content += "- **Baggage Claim:** #{details[:arrival_baggage]}\n" if details[:arrival_baggage].present?
    content += "- **Scheduled:** #{attributes[:arr_sched_at]&.strftime('%H:%M UTC')}\n"
    content += "- **Estimated:** #{attributes[:arr_est_at]&.strftime('%H:%M UTC')}\n" if attributes[:arr_est_at].present?

    if details[:arrival_actual].present?
      content += "- **Actual Arrival:** #{details[:arrival_actual].strftime('%H:%M UTC')}\n"
    end

    # Code-share info
    if details[:codeshare_info].present?
      codeshare = details[:codeshare_info]
      operating_airline = codeshare["airline_name"]&.titleize || codeshare["airline_iata"]
      operating_flight = codeshare["flight_iata"] || codeshare["flight_icao"]

      content += "\n### Code-Share\n"
      content += "This flight is operated by #{operating_airline} (#{operating_flight}).\n"

      # Show all marketing carriers
      all_flights = attributes[:route_short_name].split(" / ")
      if all_flights.length > 1
        content += "\nAlso sold as:\n"
        all_flights.each do |flight_code|
          content += "- #{flight_code}\n"
        end
      end
    end

    # Aircraft info
    if details[:aircraft_registration].present?
      content += "\n### Aircraft\n"
      content += "**Registration:** #{details[:aircraft_registration]}\n"
    end

    content += "\n_All times in UTC. Information subject to change._"
    content
  end

  private

  def self.determine_category(mode)
    case mode&.downcase
    when "flight"
      SiteSetting.transit_tracker_planes_category_id
    when "train"
      SiteSetting.transit_tracker_trains_category_id
    when "tram", "bus", "metro"
      SiteSetting.transit_tracker_public_transit_category_id
    else
      SiteSetting.transit_tracker_public_transit_category_id
    end
  end

  def self.build_title(attributes)
    route = attributes[:route_short_name]
    headsign = attributes[:headsign]
    dep_time = attributes[:dep_sched_at]&.strftime("%H:%M")

    "#{route} to #{headsign} at #{dep_time}"
  end

  def self.build_custom_fields(attributes)
    {
      "transit_service_date" => attributes[:service_date],
      "transit_origin" => attributes[:origin],
      "transit_origin_name" => attributes[:origin_name],
      "transit_dest" => attributes[:dest],
      "transit_dest_name" => attributes[:dest_name],
      "transit_dep_sched_at" => attributes[:dep_sched_at],
      "transit_dep_est_at" => attributes[:dep_est_at],
      "transit_arr_sched_at" => attributes[:arr_sched_at],
      "transit_arr_est_at" => attributes[:arr_est_at],
      "transit_platform" => attributes[:platform],
      "transit_gate" => attributes[:gate],
      "transit_terminal" => attributes[:terminal],
      "transit_route_short_name" => attributes[:route_short_name],
      "transit_route_color" => attributes[:route_color],
      "transit_headsign" => attributes[:headsign],
      "transit_trip_id" => attributes[:trip_id],
      "transit_vehicle_id" => attributes[:vehicle_id],
      "transit_source" => attributes[:source],
      "transit_stops" => attributes[:stops]&.to_json,
    }
  end

  def self.build_post_content(attributes)
    <<~CONTENT
      **Route:** #{attributes[:route_short_name]}
      **Headsign:** #{attributes[:headsign]}
      **Origin:** #{attributes[:origin_name]}
      **Destination:** #{attributes[:dest_name]}
      **Platform:** #{attributes[:platform]}

      **Scheduled Departure:** #{attributes[:dep_sched_at]&.strftime("%Y-%m-%d %H:%M UTC")}
      **Estimated Departure:** #{attributes[:dep_est_at]&.strftime("%Y-%m-%d %H:%M UTC") || "On time"}

      **Trip ID:** #{attributes[:trip_id]}
      **Vehicle ID:** #{attributes[:vehicle_id]}
    CONTENT
  end

  def self.apply_tags(topic, attributes)
    tags = []

    # Mode tag
    tags << attributes[:mode]&.downcase if attributes[:mode]

    # Status tag: Use API status if provided (source of truth), otherwise infer from timing
    status = attributes[:status] || determine_status_from_attributes(attributes)
    tags << "status:#{status}"

    # Route tag
    tags << "route:#{attributes[:route_short_name]}" if attributes[:route_short_name]

    # Remove old status tags and apply new ones
    existing_tags = topic.tags.pluck(:name)
    tags_to_remove = existing_tags.select { |t| t.start_with?("status:") }

    new_tags = (existing_tags - tags_to_remove + tags).uniq
    DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), new_tags)
  end

  def self.determine_status(topic)
    dep_sched = topic.custom_fields["transit_dep_sched_at"]
    dep_est = topic.custom_fields["transit_dep_est_at"]
    return "scheduled" unless dep_sched

    return "delayed" if delayed?(dep_sched, dep_est)
    "scheduled"
  end

  def self.determine_status_from_attributes(attributes)
    return "scheduled" unless attributes[:dep_sched_at]
    return "delayed" if delayed?(attributes[:dep_sched_at], attributes[:dep_est_at])
    "scheduled"
  end

  def self.delayed?(scheduled, estimated)
    return false unless scheduled && estimated

    # Parse strings to Time objects if needed (custom fields store as strings)
    scheduled = scheduled.is_a?(String) ? Time.parse(scheduled) : scheduled
    estimated = estimated.is_a?(String) ? Time.parse(estimated) : estimated

    delay_seconds = (estimated - scheduled).to_i
    delay_seconds > SiteSetting.transit_tracker_delay_threshold_seconds
  end

  def self.status_changed_significantly?(old_status, new_status)
    old_status != new_status && new_status == "delayed"
  end

  def self.post_status_update(topic, old_status, new_status, attributes)
    delay_minutes = ((attributes[:dep_est_at] - attributes[:dep_sched_at]) / 60).to_i

    PostCreator.create!(
      Discourse.system_user,
      topic_id: topic.id,
      raw: "⚠️ Status changed: #{old_status} → #{new_status}. Delayed by #{delay_minutes} minutes.",
      skip_validations: true,
    )
  end
end
