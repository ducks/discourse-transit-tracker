# frozen_string_literal: true

module DiscourseTransitTracker
  class BoardController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    def respond
      discourse_expires_in 1.minute

      # This renders JSON for API requests and HTML for direct navigation
      render json: {}
    end
  end
end
