# frozen_string_literal: true

module DiscourseTransitTracker
  class BoardController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :preload_json

    def respond
      discourse_expires_in 1.minute

      # This renders JSON for API requests and HTML for direct navigation
      render json: {}
    end
  end
end
