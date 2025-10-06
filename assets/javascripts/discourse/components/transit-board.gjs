import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { gt, lt, eq } from "truth-helpers";
import { concat } from "@ember/helper";
import { i18n } from "discourse-i18n";

export default class TransitBoard extends Component {
  @service router;
  @tracked departures = [];
  @tracked currentTime = new Date();
  @tracked selectedMode = null;
  @tracked expandedId = null;
  @tracked loading = false;

  refreshInterval = null;
  timeUpdateInterval = null;

  @action
  startAutoRefresh() {
    // Get mode from URL query params
    const urlParams = new URLSearchParams(window.location.search);
    this.selectedMode = urlParams.get('mode');

    // Refresh data every 30 seconds (silent refresh, no loading indicator)
    this.refreshInterval = setInterval(() => {
      this.refreshDepartures(false);
    }, 30000);

    // Update current time every second for countdown
    this.timeUpdateInterval = setInterval(() => {
      this.currentTime = new Date();
    }, 1000);

    // Initial time
    this.currentTime = new Date();

    // Initial load (show loading indicator)
    this.refreshDepartures(true);
  }

  @action
  stopAutoRefresh() {
    if (this.refreshInterval) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = null;
    }
    if (this.timeUpdateInterval) {
      clearInterval(this.timeUpdateInterval);
      this.timeUpdateInterval = null;
    }
  }

  async refreshDepartures(showLoading = false) {
    if (showLoading) {
      this.loading = true;
    }
    try {
      let url = "/transit/board";
      if (this.selectedMode) {
        url += `?mode=${this.selectedMode}`;
      }
      const data = await ajax(url);

      // Smartly update departures - only change what's different
      const newDepartures = data.departures;
      const existingIds = this.departures.map(d => d.id);
      const newIds = newDepartures.map(d => d.id);

      // Remove departures that no longer exist
      this.departures = this.departures.filter(d => newIds.includes(d.id));

      // Update existing departures and add new ones
      newDepartures.forEach(newDep => {
        const existingIndex = this.departures.findIndex(d => d.id === newDep.id);
        if (existingIndex >= 0) {
          // Update existing departure
          this.departures[existingIndex] = newDep;
        } else {
          // Add new departure
          this.departures.push(newDep);
        }
      });

      // Sort by departure time
      this.departures = this.departures.sort((a, b) => {
        const timeA = new Date(a.dep_est_at || a.dep_sched_at);
        const timeB = new Date(b.dep_est_at || b.dep_sched_at);
        return timeA - timeB;
      });
    } catch (error) {
      console.error("Failed to refresh departures:", error);
    } finally {
      if (showLoading) {
        this.loading = false;
      }
    }
  }

  @action
  filterByMode(mode) {
    this.selectedMode = mode;

    // Update URL
    const url = new URL(window.location);
    if (mode) {
      url.searchParams.set('mode', mode);
    } else {
      url.searchParams.delete('mode');
    }
    window.history.pushState({}, '', url);

    // Refresh data (show loading indicator on filter change)
    this.refreshDepartures(true);
  }

  @action
  toggleExpand(departureId, event) {
    event.stopPropagation();
    if (this.expandedId === departureId) {
      this.expandedId = null;
    } else {
      this.expandedId = departureId;
    }
  }

  @action
  viewDeparture(topicId, event) {
    // Only navigate if clicking outside the expanded area
    if (!event.target.closest('.board-row-expanded')) {
      this.router.transitionTo("topic", topicId);
    }
  }

  getStatusClass = (status) => {
    switch (status) {
      case "scheduled":
        return "status-scheduled";
      case "delayed":
        return "status-delayed";
      case "departed":
        return "status-departed";
      case "canceled":
        return "status-canceled";
      default:
        return "status-scheduled";
    }
  };

  getMinutesUntil = (depTime) => {
    if (!depTime) return null;
    const dep = new Date(depTime);
    const diff = dep - this.currentTime;
    return Math.floor(diff / 60000);
  };

  getDepartureTime = (departure) => {
    return departure.dep_est_at || departure.dep_sched_at;
  };

  getFlightCodes = (routeString) => {
    if (!routeString) return [];
    return routeString.split("/").map((code) => code.trim());
  };

  formatTime = (timeStr) => {
    if (!timeStr) return "—";
    const time = new Date(timeStr);
    const hours = String(time.getUTCHours()).padStart(2, '0');
    const minutes = String(time.getUTCMinutes()).padStart(2, '0');
    return `${hours}:${minutes}`;
  };

  get formattedCurrentTime() {
    const hours = String(this.currentTime.getHours()).padStart(2, '0');
    const minutes = String(this.currentTime.getMinutes()).padStart(2, '0');
    const seconds = String(this.currentTime.getSeconds()).padStart(2, '0');
    return `${hours}:${minutes}:${seconds}`;
  }

  <template>
    <div
      class="transit-board-container"
      {{didInsert this.startAutoRefresh}}
      {{willDestroy this.stopAutoRefresh}}
    >
      <div class="transit-board-header">
        <h1>{{i18n "transit_tracker.board"}}</h1>
        <div class="current-time">{{this.formattedCurrentTime}}</div>
      </div>

      <div class="transit-board-filters">
        <button
          class="filter-btn {{unless this.selectedMode 'active'}}"
          {{on "click" (fn this.filterByMode null)}}
        >
          {{i18n "transit_tracker.filters.all"}}
        </button>
        <button
          class="filter-btn {{if (eq this.selectedMode 'flight') 'active'}}"
          {{on "click" (fn this.filterByMode "flight")}}
        >
          {{i18n "transit_tracker.filters.flights"}}
        </button>
        <button
          class="filter-btn {{if (eq this.selectedMode 'train') 'active'}}"
          {{on "click" (fn this.filterByMode "train")}}
        >
          {{i18n "transit_tracker.filters.trains"}}
        </button>
        <button
          class="filter-btn {{if (eq this.selectedMode 'bus') 'active'}}"
          {{on "click" (fn this.filterByMode "bus")}}
        >
          {{i18n "transit_tracker.filters.buses"}}
        </button>
        <button
          class="filter-btn {{if (eq this.selectedMode 'tram') 'active'}}"
          {{on "click" (fn this.filterByMode "tram")}}
        >
          {{i18n "transit_tracker.filters.trams"}}
        </button>
        <button
          class="filter-btn {{if (eq this.selectedMode 'metro') 'active'}}"
          {{on "click" (fn this.filterByMode "metro")}}
        >
          {{i18n "transit_tracker.filters.metro"}}
        </button>
      </div>

      {{#if this.loading}}
        <div class="transit-board">
          <div class="board-empty">
            <p>Loading departures...</p>
          </div>
        </div>
      {{else}}
        <div class="transit-board">
          <div class="board-header-row">
          <div class="col-time">{{i18n "transit_tracker.columns.time"}}</div>
          <div class="col-route">{{i18n "transit_tracker.columns.route"}}</div>
          <div class="col-origin">{{i18n "transit_tracker.columns.origin"}}</div>
          <div class="col-destination">{{i18n
              "transit_tracker.columns.destination"
            }}</div>
          <div class="col-platform">
            {{#if (gt this.departures.length 0)}}
              {{#if this.departures.firstObject.gate}}
                {{i18n "transit_tracker.columns.gate"}}
              {{else}}
                {{i18n "transit_tracker.columns.platform"}}
              {{/if}}
            {{else}}
              {{i18n "transit_tracker.columns.platform"}}
            {{/if}}
          </div>
          <div class="col-status">{{i18n "transit_tracker.columns.status"}}</div>
          <div class="col-countdown">{{i18n
              "transit_tracker.columns.countdown"
            }}</div>
        </div>

        {{#each this.departures as |departure|}}
          <div class="board-row-wrapper">
            <div
              class="board-row {{this.getStatusClass departure.status}} {{if (eq this.expandedId departure.id) 'expanded'}}"
              role="button"
              tabindex="0"
              {{on "click" (fn this.toggleExpand departure.id)}}
            >
              <div class="col-time">
                {{#if departure.dep_est_at}}
                  {{this.formatTime departure.dep_est_at}}
                {{else}}
                  {{this.formatTime departure.dep_sched_at}}
                {{/if}}
              </div>

              <div class="col-route">
                {{#each (this.getFlightCodes departure.route) as |code|}}
                  <span
                    class="route-badge mode-{{departure.mode}}"
                    style="{{if departure.route_color (concat 'background: linear-gradient(135deg, #' departure.route_color ' 0%, #' departure.route_color ' 100%) !important; border-color: #' departure.route_color ' !important;')}}"
                  >
                    {{code}}
                  </span>
                {{/each}}
              </div>

              <div class="col-origin">
                <div class="origin-main">{{departure.origin_name}}</div>
                {{#if departure.origin}}
                  <div class="origin-code">{{departure.origin}}</div>
                {{/if}}
              </div>

              <div class="col-destination">
                <div class="destination-main">{{departure.headsign}}</div>
                {{#if departure.dest}}
                  <div class="destination-code">{{departure.dest}}</div>
                {{/if}}
              </div>

              <div class="col-platform">
                {{#if departure.platform}}
                  {{departure.platform}}
                {{else if departure.gate}}
                  {{departure.gate}}
                {{else}}
                  —
                {{/if}}
              </div>

              <div class="col-status">
                <span class="status-badge">
                  {{#if departure.status}}
                    {{i18n (concat "transit_tracker.status." departure.status)}}
                  {{else}}
                    {{i18n "transit_tracker.status.scheduled"}}
                  {{/if}}
                </span>
              </div>

              <div class="col-countdown">
                {{#let (this.getMinutesUntil (this.getDepartureTime departure)) as |minutes|}}
                  {{#if minutes}}
                    {{#if (gt minutes 0)}}
                      {{minutes}}
                      {{i18n "transit_tracker.minutes"}}
                    {{else if (lt minutes -5)}}
                      {{i18n "transit_tracker.departed"}}
                    {{else}}
                      {{i18n "transit_tracker.now"}}
                    {{/if}}
                  {{else}}
                    —
                  {{/if}}
                {{/let}}
              </div>
            </div>

            {{#if (eq this.expandedId departure.id)}}
              <div class="board-row-expanded">
                {{#if (gt departure.stops.length 2)}}
                  <div class="departure-post">
                    <h2>Complete Schedule</h2>
                    <p><strong>Line:</strong> {{departure.route}}</p>
                    <p><strong>Direction:</strong> {{departure.headsign}}</p>
                    <table>
                      <thead>
                        <tr>
                          <th>Stop</th>
                          <th>Arrival</th>
                          <th>Departure</th>
                        </tr>
                      </thead>
                      <tbody>
                        {{#each departure.stops as |stop|}}
                          <tr>
                            <td>{{stop.stop_name}}</td>
                            <td>{{if stop.arrival_time (this.formatTime stop.arrival_time) "—"}}</td>
                            <td>{{if stop.departure_time (this.formatTime stop.departure_time) "—"}}</td>
                          </tr>
                        {{/each}}
                      </tbody>
                    </table>
                    <p><em>Schedule times are in UTC. This is the planned schedule and may be subject to delays.</em></p>
                  </div>
                {{else}}
                  <div class="departure-post">
                    <p><em>No additional details available</em></p>
                  </div>
                {{/if}}
              </div>
            {{/if}}
          </div>
        {{else}}
          <div class="board-empty">
            <p>{{i18n "transit_tracker.no_departures"}}</p>
          </div>
        {{/each}}
      </div>
      {{/if}}
    </div>
  </template>
}
