# Claude Context for Transit Tracker

Context and important decisions for AI assistants working on this project.

## Project Overview

This is a Discourse plugin that turns a forum into a live transit departure board. It imports real transit data (trains, flights, subways) and displays them in a split-flap airport/train station display style.

**Core concept**: Each departure is a Discourse topic. Schedule details are stored as posts. Tags are used for filtering (mode, status, route).

## Key Design Decisions

### Why Topics Instead of Custom Tables?

- Leverages Discourse's existing infrastructure (search, moderation, API)
- Posts provide natural storage for schedule details and updates
- Tags enable filtering without custom indexes
- Topics can be discussed/commented on by users
- Native mobile app support
- Easy to query and display

### Data Sources

1. **Amtrak** - GTFS feed for US trains
2. **AviationStack** - REST API for flights with code-share detection
3. **MTA** - GTFS feed for NYC subway (huge dataset, needs special handling)

### Performance Critical Decisions

**Problem**: MTA GTFS contains 500k+ stop_times for all trains. Loading all into memory eats 19GB RAM.

**Solutions implemented**:
- 6-hour import window instead of 24-hour (reduces topics created)
- Query optimization: For metro, grab 5 departures per route (25 routes × 5 = ~125 topics instead of 2000+)
- Remove eager loading of posts - render schedules from stops JSON instead
- Smart refresh: Update changed items in-place, no full array replacement
- Silent auto-refresh every 30s with no UI flash

**Do NOT**:
- Load all posts upfront (`.includes(:posts)`)
- Query all metro topics without per-route limiting
- Replace entire departures array on refresh (causes flash)

### GTFS Time Handling

GTFS uses "service time" not wall clock time. Times can exceed 24 hours:
- `25:30:00` = 1:30 AM next day
- `27:45:00` = 3:45 AM next day

This is intentional! Service day starts at like 3-4 AM and runs through 2-3 AM the next calendar day.

**Implementation**: `parse_gtfs_time` method handles this by calculating `days_offset = hours / 24` and adding days.

### Code-Share Flight Handling

AviationStack provides a `codeshared` field with the operating carrier.

**Pattern**:
- Use operating carrier flight number as `trip_id` (natural key)
- Marketing carriers get merged into the same topic
- Display as "AA 1234 / BA 5678" (all code-shares on one line)
- This automatically deduplicates - one flight, multiple airline codes

### MTA Route Colors

MTA GTFS includes `route_color` field with hex values (no `#` prefix).

**Implementation**:
- Store in `transit_route_color` custom field
- Apply as inline style: `style="background: linear-gradient(135deg, #{{color}} 0%, #{{color}} 100%)"`
- Shows authentic MTA colors: red 1/2/3, green 4/5/6, yellow N/Q/R/W, blue A/C/E, orange B/D/F/M, purple 7, etc.

## Important Patterns

### Custom Fields

All transit data stored as topic custom fields. **Must be registered in `plugin.rb`** or they won't save:

```ruby
register_topic_custom_field_type("transit_route_color", :string)
```

Forgot to register? Data silently won't save. Check plugin.rb first when custom fields don't persist.

### Query Pattern for Metro

```ruby
# Get distinct routes
route_names = Topic.joins(:tags, custom_fields).pluck('value')

# Get 5 per route (N queries, but fast with indexes)
route_names.each do |route|
  topics_query.where("tcf.value = ?", route).limit(5)
end
```

This is intentional N+1. Window functions would be one query but complex SQL. This approach is fast enough (~500ms) and maintainable.

### Schedule Rendering

**Don't** store schedule as HTML post - render from `stops` JSON:

```javascript
{{#each departure.stops as |stop|}}
  <tr>
    <td>{{stop.stop_name}}</td>
    <td>{{formatTime stop.arrival_time}}</td>
  </tr>
{{/each}}
```

This avoids loading posts, enables instant rendering, and keeps data canonical.

## Gotchas and Sharp Edges

### Rails 8 Compatibility

On July 2nd 2024, Discourse upgraded to Rails 8. Old controller callbacks were removed:
- ~~`skip_before_action :check_xhr`~~
- ~~`skip_before_action :preload_json`~~
- ~~`skip_before_action :verify_authenticity_token`~~

**Remove these lines** - they'll cause `callback has not been defined` errors.

### GTFS Import Memory Usage

MTA GTFS is massive. Running full 24-hour import:
- Loads 500k+ stop_times into memory
- Creates 19,000+ topics
- Uses 18GB RAM

**Always use 6-hour window** for MTA (`now + 6.hours`).

### Time Zones

All times stored as UTC. GTFS times are interpreted as UTC. Display handles timezone conversion.

**Don't** try to guess local timezones from stop coordinates - just use UTC everywhere.

### Metro Board Performance

With 2500+ metro topics, the board was slow (~3 seconds). Optimizations applied:

1. Query only 5 per route (125 topics total)
2. Remove `.includes(:posts)`
3. Loading indicator on filter change
4. Silent background refresh

**Do NOT** revert to querying all metro topics without limit.

## Testing and Debugging

### Import Tasks

```bash
bin/rails transit_tracker:import_amtrak
bin/rails transit_tracker:import_mta
```

### Check Data

```bash
# Count by mode
bin/rails runner "Topic.joins(:tags).where(tags: {name: 'metro'}).count"

# Check custom fields
bin/rails runner "t = Topic.joins(:tags).where(tags: {name: 'metro'}).first; puts t.custom_fields.inspect"

# Route distribution
bin/rails runner "Topic.joins(:tags).where(tags: {name: 'metro'}).group('topic_custom_fields.value').count"
```

### Performance Profiling

Add to controller:
```ruby
Rails.logger.info "Query time: #{Benchmark.realtime { topics = topics_query.to_a }}"
```

### Common Issues

**Schedule post not showing**: Check if `existing_schedule_post` query finds Post #2
**Colors not showing**: Verify `transit_route_color` registered in plugin.rb
**Slow metro filter**: Check if querying 2000+ topics or N queries per route
**Auto-refresh flash**: Verify smart refresh logic compares by ID

## Extension Points

### Adding New Transit Source

1. Create service class (e.g., `BartGtfsService`)
2. Follow GTFS or REST API pattern from existing services
3. Add rake task in `lib/tasks/`
4. Set `mode` tag appropriately (train/metro/tram/bus)
5. Add mode-specific colors in CSS if needed

### Adding Real-Time Updates

Current design: Scheduled data only. To add real-time:

1. Create `TransitRealtimeService`
2. Match by `trip_id`
3. Update `transit_dep_est_at`, `transit_arr_est_at`
4. Update status tags (delayed, canceled)
5. Auto-refresh already handles showing changes

### Adding More Filters

Already filtered by mode. To add more:

1. Add filter buttons in component
2. Update `filterByMode` to accept multiple params
3. Update controller query to filter by additional custom fields/tags
4. Use same per-route limit pattern for performance

## File Guide

- `app/models/transit_leg.rb` - Core model, handles topic creation/updates
- `app/services/*_service.rb` - Import services for each data source
- `app/controllers/transit_board_controller.rb` - API endpoint, query optimization
- `assets/javascripts/discourse/components/transit-board.gjs` - Main UI component
- `assets/stylesheets/transit-board.scss` - Split-flap display styling
- `plugin.rb` - Custom field registration, asset loading

## Future Considerations

### Scheduled Cleanup

Old departures accumulate. Consider adding:

```ruby
# Delete departed trains older than 24 hours
Topic.joins(:tags)
  .where(tags: { name: %w[train metro bus tram] })
  .where("custom_fields.transit_dep_sched_at < ?", 24.hours.ago)
  .destroy_all
```

### Caching

Board queries could be cached for 30s:

```ruby
Rails.cache.fetch("transit_board_#{mode_filter}", expires_in: 30.seconds) do
  # expensive query
end
```

### Pagination

If routes grow beyond 25, consider paginating metro results or adding "Load more" button.

## Historical Notes

**The 19GB RAM Incident**: First MTA import used 24-hour window. Loaded entire GTFS into memory, tried to create 19,000 topics, ate 19GB RAM. Reduced to 6 hours, problem solved.

**The G Train**: Only NYC subway line that doesn't enter Manhattan. Runs Brooklyn to Queens. Always gets disrespected. We made sure it shows up on the board.

**Rails 8 Upgrade Mystery**: Plugin worked all weekend, then suddenly failed with callback errors. Discourse had upgraded to Rails 8 two days prior but old code was cached in memory. Fresh restart exposed the incompatibility.
