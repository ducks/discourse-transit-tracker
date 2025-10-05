# frozen_string_literal: true

class TransitBoardController < ApplicationController
  skip_before_action :check_xhr, :preload_json, :verify_authenticity_token

  def index
    category_ids = [
      SiteSetting.transit_tracker_planes_category_id,
      SiteSetting.transit_tracker_trains_category_id,
      SiteSetting.transit_tracker_public_transit_category_id,
    ].compact.reject(&:zero?)

    return render json: { departures: [] } if category_ids.empty?

    # Get topics with transit data
    topics =
      Topic
        .where(category_id: category_ids)
        .where(deleted_at: nil)
        .where(
          "EXISTS (SELECT 1 FROM topic_custom_fields WHERE topic_id = topics.id AND name = 'transit_trip_id')",
        )
        .includes(:tags, :posts)
        .limit(200)

    # Filter and sort by departure time (est or scheduled)
    now = Time.now
    time_window_start = now - 24.hours  # Show flights from last 24 hours
    time_window_end = now + 24.hours    # Show flights for next 24 hours

    topics_with_times =
      topics.map do |topic|
        dep_time_str =
          topic.custom_fields["transit_dep_est_at"] ||
            topic.custom_fields["transit_dep_sched_at"]
        dep_time = begin
          dep_time_str.is_a?(String) ? Time.parse(dep_time_str) : dep_time_str
        rescue
          nil
        end
        [topic, dep_time]
      end

    # Filter to flights within time window
    filtered_topics = topics_with_times.select do |_, time|
      time && time >= time_window_start && time <= time_window_end
    end

    sorted_topics = filtered_topics.sort_by { |_, time| time }.map(&:first)

    # Serialize departures
    departures = sorted_topics.map { |topic| serialize_departure(topic) }

    # Filter by mode if specified
    mode_filter = params[:mode]
    if mode_filter.present?
      departures = departures.select { |d| d[:mode] == mode_filter }
    end

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

    # Get posts (excluding the first OP, include schedule and updates)
    posts = topic.posts.where("post_number > 1").order(:post_number).map do |post|
      {
        id: post.id,
        post_number: post.post_number,
        cooked: post.cooked,
        created_at: post.created_at,
        username: post.user.username
      }
    end

    {
      id: topic.id,
      title: topic.title,
      mode: mode_tag,
      status: status_tag,
      route: topic.custom_fields["transit_route_short_name"],
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
      posts: posts,
    }
  end
end
