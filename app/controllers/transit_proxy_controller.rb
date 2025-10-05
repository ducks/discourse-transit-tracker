# frozen_string_literal: true

class TransitProxyController < ApplicationController
  # Optional proxy endpoint for external API calls
  # Whitelist specific query parameters to prevent abuse

  ALLOWED_PARAMS = %w[ids minutesBefore minutesAfter limit]

  def index
    return render json: { error: "Not enabled" }, status: :forbidden unless SiteSetting.transit_tracker_enabled

    stop_ids = params[:ids]
    return render json: { error: "Missing stop IDs" }, status: :bad_request if stop_ids.blank?

    # Build request to Golemio API
    url = "https://api.golemio.cz/v2/pid/departureboards"

    response =
      Faraday.get(url) do |req|
        req.headers["X-Access-Token"] = SiteSetting.transit_tracker_golemio_api_token
        req.headers["Content-Type"] = "application/json"

        ALLOWED_PARAMS.each do |param|
          req.params[param] = params[param] if params[param].present?
        end
      end

    if response.success?
      render json: JSON.parse(response.body)
    else
      render json: { error: "API request failed" }, status: :bad_gateway
    end
  rescue => e
    Rails.logger.error "[TransitTracker] Proxy request failed: #{e.message}"
    render json: { error: "Internal error" }, status: :internal_server_error
  end
end
