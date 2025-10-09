# frozen_string_literal: true

class TransitBoardController < ApplicationController
  def index
    category_ids = [
      SiteSetting.transit_tracker_planes_category_id,
      SiteSetting.transit_tracker_trains_category_id,
      SiteSetting.transit_tracker_public_transit_category_id,
    ].compact.reject(&:zero?)

    return render json: { departures: [] } if category_ids.empty?

    # Build base query
    topics_query =
      Topic
        .where(category_id: category_ids)
        .where(deleted_at: nil)
        .where(
          "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = 'transit_trip_id')",
        )
        .includes(:tags, :posts)
        .preload(:_custom_fields)

    # Filter by mode if specified - do this at the database level
    mode_filter = params[:mode]
    if mode_filter.present?
      topics_query = topics_query.joins(:tags).where(tags: { name: mode_filter })
    end

    # For demo: filter by time-of-day only (ignore date)
    now = Time.now.utc
    current_minutes = now.hour * 60 + now.min
    window_minutes = 120 # 2 hours

    # For metro, get 5 departures per route for better variety
    if mode_filter == "metro"
      # Get all distinct routes
      route_names =
        Topic
          .joins(:tags)
          .joins(
            "INNER JOIN topic_custom_fields tcf ON topics.id = tcf.topic_id AND tcf.name = 'transit_route_short_name'",
          )
          .where(tags: { name: "metro" })
          .where(category_id: category_ids)
          .where(deleted_at: nil)
          .distinct
          .pluck("tcf.value")

      # Get first 5 topics for each route, ordered by departure time
      topics = []
      route_names.each do |route|
        route_topics =
          topics_query
            .joins(
              "INNER JOIN topic_custom_fields tcf ON topics.id = tcf.topic_id AND tcf.name = 'transit_route_short_name'",
            )
            .joins(
              "INNER JOIN topic_custom_fields dep ON topics.id = dep.topic_id AND dep.name = 'transit_dep_sched_at'",
            )
            .where("tcf.value = ?", route)
            .order("(dep.value::timestamptz AT TIME ZONE 'UTC')::time ASC")
            .limit(5)
            .to_a
        topics.concat(route_topics)
      end
    else
      topics =
        topics_query
          .joins(
            "INNER JOIN topic_custom_fields dep ON topics.id = dep.topic_id AND dep.name = 'transit_dep_sched_at'",
          )
          .order("(dep.value::timestamptz AT TIME ZONE 'UTC')::time ASC")
          .limit(200)
    end

    # Filter by time-of-day window (ignore date)
    filtered_topics = topics.select do |topic|
      dep_time_str = topic.custom_fields["transit_dep_est_at"] || topic.custom_fields["transit_dep_sched_at"]
      next false unless dep_time_str

      begin
        dep_time = dep_time_str.is_a?(String) ? Time.parse(dep_time_str) : dep_time_str
        dep_minutes = dep_time.hour * 60 + dep_time.min

        # Check if within window (handles midnight wrap-around)
        diff = (dep_minutes - current_minutes) % 1440 # minutes in a day
        diff <= window_minutes
      rescue
        false
      end
    end

    # Serialize departures
    departures = filtered_topics.map { |topic| serialize_departure(topic) }

    render json: { departures: departures }
  end

  private

  def serialize_departure(topic)
    tags = topic.tags.pluck(:name)
    mode_tag = tags.find { |t| %w[flight train tram bus metro].include?(t) }
    status_tag = tags.find { |t| t.start_with?("status:") }&.sub("status:", "")
    route_tag = tags.find { |t| t.start_with?("route:") }&.sub("route:", "")

    stops_json = topic.custom_fields["transit_stops"]
    stops = stops_json ? JSON.parse(stops_json) : []

    # For flights, include the details post content (Post #2)
    details_html = nil
    if mode_tag == "flight"
      details_post = topic.posts.where(post_number: 2).first
      details_html = details_post&.cooked
    end

    {
      id: topic.id,
      title: topic.title,
      mode: mode_tag,
      status: status_tag,
      route: topic.custom_fields["transit_route_short_name"],
      route_color: topic.custom_fields["transit_route_color"],
      headsign: topic.custom_fields["transit_headsign"],
      platform: topic.custom_fields["transit_platform"],
      gate: topic.custom_fields["transit_gate"],
      terminal: topic.custom_fields["transit_terminal"],
      dep_sched_at: topic.custom_fields["transit_dep_sched_at"],
      dep_est_at: topic.custom_fields["transit_dep_est_at"],
      arr_sched_at: topic.custom_fields["transit_arr_sched_at"],
      arr_est_at: topic.custom_fields["transit_arr_est_at"],
      origin: topic.custom_fields["transit_origin"],
      origin_name: topic.custom_fields["transit_origin_name"],
      dest: topic.custom_fields["transit_dest"],
      dest_name: topic.custom_fields["transit_dest_name"],
      stops: stops,
      details_html: details_html,
    }
  end
end
