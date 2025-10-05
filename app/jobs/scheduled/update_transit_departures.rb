# frozen_string_literal: true

module Jobs
  class UpdateTransitDepartures < ::Jobs::Scheduled
    every SiteSetting.transit_tracker_polling_interval_minutes.minutes

    def execute(args)
      # Disabled automatic updates to save API credits
      # Run manually with: bin/rails runner "TransitUpdaterService.update_all"
      return

      return unless SiteSetting.transit_tracker_enabled

      TransitUpdaterService.update_all
    end
  end
end
