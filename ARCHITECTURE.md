# Transit Tracker Architecture

Technical architecture documentation for the Discourse Transit Tracker plugin.

## System Overview

```
┌─────────────────┐
│  GTFS Feeds     │ (Amtrak, MTA)
│  REST APIs      │ (AviationStack)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Import Services │ (Background jobs, rake tasks)
│  - Parse data   │
│  - Create topics│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Discourse       │
│  Topics (JSON)  │ ← Each departure is a topic
│  Posts          │ ← Schedule details
│  Tags           │ ← Mode, status, route filters
│  Custom Fields  │ ← Transit metadata
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Board API       │ (TransitBoardController)
│  - Query topics │
│  - Filter/sort  │
│  - Serialize    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Transit Board   │ (Ember/Glimmer component)
│  - Split-flap UI│
│  - Auto-refresh │
│  - Expandable   │
└─────────────────┘
```

## Data Model

### Topic Structure

Each departure = one Discourse topic:

```
Topic #12345: "1 to South Ferry"
├── Tags: ["metro", "status:scheduled", "route:1"]
├── Category: Public Transit (ID: 7)
├── Custom Fields:
│   ├── transit_trip_id: "1_20251006_123456"
│   ├── transit_route_short_name: "1"
│   ├── transit_route_color: "EE352E"
│   ├── transit_headsign: "South Ferry"
│   ├── transit_origin: "137 St - City College"
│   ├── transit_origin_name: "137 St"
│   ├── transit_dest: "142"
│   ├── transit_dest_name: "South Ferry"
│   ├── transit_dep_sched_at: "2025-10-06 16:17:00 UTC"
│   ├── transit_arr_sched_at: "2025-10-06 16:45:00 UTC"
│   ├── transit_source: "mta"
│   └── transit_stops: "[{stop_id, stop_name, arrival_time, ...}, ...]"
└── Posts:
    └── Post #2 (optional): Schedule markdown table
```

### Custom Fields Reference

| Field | Type | Purpose |
|-------|------|---------|
| `transit_trip_id` | string | Natural key for deduplication |
| `transit_route_short_name` | string | Display name (e.g., "1", "AA 1234") |
| `transit_route_color` | string | Hex color (no #) for route badges |
| `transit_headsign` | string | Destination/direction text |
| `transit_origin` | string | Origin stop code |
| `transit_origin_name` | string | Origin stop full name |
| `transit_dest` | string | Destination stop code |
| `transit_dest_name` | string | Destination stop name |
| `transit_dep_sched_at` | datetime | Scheduled departure (UTC) |
| `transit_dep_est_at` | datetime | Estimated departure (UTC, optional) |
| `transit_arr_sched_at` | datetime | Scheduled arrival (UTC) |
| `transit_arr_est_at` | datetime | Estimated arrival (UTC, optional) |
| `transit_platform` | string | Platform/track number |
| `transit_gate` | string | Gate number (flights) |
| `transit_terminal` | string | Terminal (flights) |
| `transit_source` | string | Data source: "amtrak", "mta", "aviationstack" |
| `transit_stops` | json | Array of stop objects with times/coordinates |

### Tags Schema

**Mode tags** (mutually exclusive):
- `flight` - Air travel
- `train` - Intercity trains (Amtrak)
- `metro` - Subway/underground
- `tram` - Light rail/streetcar
- `bus` - Bus service

**Status tags** (mutually exclusive):
- `status:scheduled` - On time
- `status:delayed` - Running late
- `status:departed` - Already left
- `status:canceled` - Trip canceled
- `status:boarding` - Currently boarding
- `status:arrived` - Arrived at destination

**Route tags** (optional):
- `route:1` - Route identifier
- Used for filtering, though custom fields are primary source

## Import Flow

### GTFS Import (Amtrak, MTA)

```ruby
# 1. Download ZIP file
URI.open(GTFS_URL) { |f| tempfile.write(f.read) }

# 2. Extract CSV files
Zip::File.open(tempfile) do |zip|
  routes_csv = read_zip_entry(zip, "routes.txt")
  stops_csv = read_zip_entry(zip, "stops.txt")
  trips_csv = read_zip_entry(zip, "trips.txt")
  stop_times_csv = read_zip_entry(zip, "stop_times.txt")
end

# 3. Parse CSVs into hashes
routes = parse_routes(routes_csv)      # { route_id => {short_name, color, ...} }
stops = parse_stops(stops_csv)         # { stop_id => {name, lat, lon, ...} }
trips = parse_trips(trips_csv)         # { trip_id => {route_id, headsign, ...} }
stop_times = parse_stop_times(...)     # [{ trip_id, stop_id, arrival_time, ...}, ...]

# 4. Filter to time window
stop_times_by_trip = stop_times.group_by { |st| st[:trip_id] }
trips.each do |trip_id, trip_data|
  first_stop = stop_times_by_trip[trip_id].first
  dep_time = parse_gtfs_time(today, first_stop[:departure_time])
  next if dep_time < now || dep_time > (now + 6.hours)

  # 5. Create/update topic
  TransitLeg.create_or_update(departure_data)
end
```

### REST API Import (AviationStack)

```ruby
# 1. HTTP GET with API key
response = URI.open("#{API_URL}?access_key=#{key}&flight_status=scheduled")
json = JSON.parse(response.read)

# 2. Transform API response
json["data"].each do |flight|
  departure_data = {
    mode: "flight",
    trip_id: "#{flight['iata']}-#{departure_time}",
    route_short_name: flight["iata"],
    origin: flight["departure"]["iata"],
    dest: flight["arrival"]["iata"],
    # ... map all fields
  }

  # 3. Handle code-shares
  if flight["codeshared"]
    trip_id = operating_flight_number  # Use operating carrier as natural key
    # Marketing carriers get merged later
  end

  TransitLeg.create_or_update(departure_data)
end
```

## Query Architecture

### Board Controller Query Flow

```ruby
# 1. Base query (all transit topics in configured categories)
topics_query = Topic
  .where(category_id: [5, 6, 7])
  .where(deleted_at: nil)
  .where("EXISTS (SELECT 1 FROM topic_custom_fields WHERE name = 'transit_trip_id')")
  .includes(:tags)

# 2. Filter by mode (if specified)
if mode == "metro"
  topics_query = topics_query.joins(:tags).where(tags: { name: 'metro' })
end

# 3. Per-route limiting (metro only)
if mode == "metro"
  route_names = get_distinct_routes()  # ~25 routes for MTA

  topics = []
  route_names.each do |route|
    # Get 5 topics per route
    route_topics = topics_query
      .joins("INNER JOIN topic_custom_fields tcf ON ...")
      .where("tcf.value = ?", route)
      .limit(5)
    topics.concat(route_topics)
  end
  # Result: ~125 topics (25 routes × 5)
else
  topics = topics_query.limit(200)
end

# 4. Filter by departure time (in Ruby)
filtered = topics.select do |topic|
  dep_time = parse_custom_field(topic, 'transit_dep_sched_at')
  dep_time >= (now - 24.hours) && dep_time <= (now + 24.hours)
end

# 5. Sort by departure time
sorted = filtered.sort_by { |t| get_departure_time(t) }

# 6. Serialize to JSON
departures = sorted.map { |topic| serialize_departure(topic) }
```

### Why Per-Route Limiting?

**Without limiting**:
- Query: 2000+ metro topics
- Load time: ~3 seconds
- Result: First 200 are all 1/2/3 trains (no variety)

**With per-route limiting**:
- Query: 25 queries × 5 topics = 125 topics total
- Load time: ~500ms
- Result: All routes represented evenly

Trade-off: N queries (one per route) vs. one massive query. N queries are fast with proper indexes and much simpler than SQL window functions.

## Frontend Architecture

### Component Structure

```javascript
TransitBoard (transit-board.gjs)
├── @tracked departures = []        // Array of departure objects
├── @tracked loading = false        // Loading indicator state
├── @tracked selectedMode = null    // Current filter
├── @tracked expandedId = null      // Currently expanded row
└── Methods:
    ├── refreshDepartures(showLoading)  // Fetch data, smart merge
    ├── filterByMode(mode)              // Change filter, update URL
    ├── toggleExpand(id)                // Expand/collapse schedule
    └── Auto-refresh (30s interval)     // Silent background update
```

### Smart Refresh Logic

```javascript
async refreshDepartures(showLoading) {
  const newDepartures = await fetch(`/transit/board?mode=${mode}`)

  // Compare old vs new by ID
  const existingIds = this.departures.map(d => d.id)
  const newIds = newDepartures.map(d => d.id)

  // Remove departures that no longer exist
  this.departures = this.departures.filter(d => newIds.includes(d.id))

  // Update existing + add new
  newDepartures.forEach(newDep => {
    const existingIndex = this.departures.findIndex(d => d.id === newDep.id)
    if (existingIndex >= 0) {
      this.departures[existingIndex] = newDep  // Update in place
    } else {
      this.departures.push(newDep)              // Add new
    }
  })

  // Re-sort by departure time
  this.departures.sort((a, b) => compareTime(a, b))
}
```

**Benefits**:
- No full array replacement (no flash/flicker)
- Only re-renders changed rows
- Expanded rows stay expanded
- Works with 30s auto-refresh

### Schedule Rendering

Schedules render directly from `stops` JSON (no post loading):

```handlebars
{{#if (eq this.expandedId departure.id)}}
  <div class="board-row-expanded">
    <table>
      {{#each departure.stops as |stop|}}
        <tr>
          <td>{{stop.stop_name}}</td>
          <td>{{formatTime stop.arrival_time}}</td>
          <td>{{formatTime stop.departure_time}}</td>
        </tr>
      {{/each}}
    </table>
  </div>
{{/if}}
```

**Why not use Post #2?**:
- Posts require `.includes(:posts)` which is expensive
- Schedule data already in `stops` JSON
- Instant rendering vs. database query
- Keeps single source of truth

## Performance Optimizations

### 1. Remove Eager Post Loading

**Before**:
```ruby
topics_query.includes(:tags, :posts)  # Loads all posts for all topics
```

**After**:
```ruby
topics_query.includes(:tags)  # Tags only, render schedule from stops JSON
```

**Impact**: 2-3 second reduction in load time

### 2. Per-Route Limiting (Metro)

**Before**: Load 2000 topics, filter to 200 in Ruby
**After**: Load 5 per route (125 total)
**Impact**: ~80% reduction in data loaded

### 3. Smart Array Updates

**Before**: `this.departures = newArray` (full replacement)
**After**: Compare by ID, update in place
**Impact**: Eliminates flash on auto-refresh

### 4. Loading States

- Show loading indicator on filter change (user feedback)
- Silent refresh on 30s interval (no indicator)
- Loading state prevents double-clicks

### Database Indexes (Recommended)

```sql
-- Speed up custom field queries
CREATE INDEX idx_tcf_transit_route ON topic_custom_fields(name, value)
  WHERE name = 'transit_route_short_name';

CREATE INDEX idx_tcf_transit_trip ON topic_custom_fields(name, value)
  WHERE name = 'transit_trip_id';

-- Speed up tag filtering
CREATE INDEX idx_tags_mode ON tags(name)
  WHERE name IN ('flight', 'train', 'metro', 'bus', 'tram');
```

## Extension Guide

### Adding a New Data Source

1. **Create service class**: `app/services/bart_gtfs_service.rb`

```ruby
class BartGtfsService
  GTFS_URL = "https://bart.gov/gtfs.zip"

  def import
    # Follow pattern from AmtrakGtfsService or MtaGtfsService
    gtfs_data = download_and_extract_gtfs
    routes = parse_routes(gtfs_data[:routes])
    # ... etc

    departure_data = {
      mode: "metro",  # or "train", "tram", etc.
      source: "bart",
      # ... all required fields
    }

    TransitLeg.create_or_update(departure_data)
  end
end
```

2. **Create rake task**: `lib/tasks/bart_import.rake`

```ruby
task "transit_tracker:import_bart" => :environment do
  service = BartGtfsService.new
  stats = service.import
  puts "✓ BART import complete! #{stats[:departures_created]} departures created"
end
```

3. **Test import**: `bin/rails transit_tracker:import_bart`

### Adding Real-Time Updates

Currently: Static schedules only

To add real-time:

1. **Create updater service**: `app/services/mta_realtime_service.rb`

```ruby
class MtaRealtimeService
  def update_departures
    # Fetch real-time feed (GTFS-RT or REST API)
    real_time_data.each do |update|
      # Find topic by trip_id
      topic = Topic.joins(:topic_custom_fields)
        .where(topic_custom_fields: {
          name: 'transit_trip_id',
          value: update[:trip_id]
        }).first

      next unless topic

      # Update estimated times
      topic.custom_fields["transit_dep_est_at"] = update[:estimated_departure]
      topic.custom_fields["transit_arr_est_at"] = update[:estimated_arrival]
      topic.save_custom_fields

      # Update status tags
      if update[:delayed]
        topic.tags = topic.tags.reject { |t| t.start_with?("status:") }
        topic.tags << Tag.find_or_create_by(name: "status:delayed")
        topic.save
      end
    end
  end
end
```

2. **Schedule job**: Run every 60 seconds

```ruby
module Jobs
  class UpdateTransitRealtime < ::Jobs::Scheduled
    every 1.minute

    def execute(args)
      MtaRealtimeService.new.update_departures
    end
  end
end
```

3. **Frontend auto-refresh** already handles showing changes

## Security Considerations

### API Keys

Store in site settings, never commit:

```ruby
# config/settings.yml
transit_tracker_aviationstack_api_key:
  default: ''
  secret: true
```

Access: `SiteSetting.transit_tracker_aviationstack_api_key`

### Rate Limiting

Add to import services:

```ruby
def import
  return if @last_import && @last_import > 5.minutes.ago
  @last_import = Time.now
  # ... import logic
end
```

### Input Validation

All GTFS/API data sanitized before storage:

```ruby
headsign: row["trip_headsign"]&.truncate(200),  # Limit length
trip_id: row["trip_id"]&.gsub(/[^a-zA-Z0-9_-]/, ''),  # Sanitize ID
```

## Deployment Notes

### First Deploy

1. Configure categories in settings:
   - Planes category
   - Trains category
   - Public transit category

2. Run initial imports:
```bash
bin/rails transit_tracker:import_amtrak
bin/rails transit_tracker:import_mta
```

3. Set up scheduled job for updates (if using real-time)

### Ongoing Maintenance

- **Cleanup old departures**: Delete topics with `dep_sched_at < 24.hours.ago`
- **Monitor import errors**: Check `stats[:errors]` in rake output
- **Database size**: Each departure = 1 topic. Consider retention policy.

### Monitoring

Key metrics:
- Import success rate (`departures_created` / `trips_processed`)
- Board query time (log in controller)
- Topic count by mode
- Failed imports (check logs for `Rails.logger.error`)
