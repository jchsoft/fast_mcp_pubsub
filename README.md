# FastMcp PubSub

**Multi-worker cluster support extension for [fast-mcp](https://github.com/yjacquin/fast-mcp) gem.**

This gem extends the [FastMcp](https://github.com/yjacquin/fast-mcp) gem to work with multiple Puma workers by adding PostgreSQL NOTIFY/LISTEN clustering support for `FastMcp::Transports::RackTransport` in Rails applications.

## Problem

FastMcp::Transports::RackTransport stores SSE clients in an in-memory hash `@sse_clients`. In cluster mode (multiple Puma workers), messages don't reach between workers because each has its own memory space.

## Solution

This gem provides PostgreSQL NOTIFY/LISTEN system for broadcasting messages between workers:

1. `send_message` → PostgreSQL NOTIFY
2. Listener thread in each worker → PostgreSQL LISTEN  
3. On notification → `send_local_message` to local clients

## Installation

**Prerequisites**: This gem requires the [fast-mcp](https://github.com/yjacquin/fast-mcp) gem to be installed first.

Add both gems to your application's Gemfile:

```ruby
gem 'fast-mcp', '~> 1.5.0'      # Required base gem
gem 'fast_mcp_pubsub'           # This extension
```

And then execute:

```bash
bundle install
```

**Note**: The `fast-mcp` gem provides the core MCP (Model Context Protocol) server functionality, while this gem extends it with multi-worker support.

## Usage

### Basic Configuration

```ruby
# config/initializers/fast_mcp_pubsub.rb
FastMcpPubsub.configure do |config|
  config.enabled = Rails.env.production? # Enable in production cluster mode
  config.channel_name = 'mcp_broadcast'  # PostgreSQL NOTIFY channel
  config.auto_start = true               # Start listener automatically
  config.logger = Rails.logger           # Use Rails logger
end
```

### Puma Cluster Mode

Works automatically with Puma cluster mode. The gem hooks into Puma's worker boot process:

```ruby
# config/puma/production.rb
workers ENV.fetch("WEB_CONCURRENCY") { 2 }
preload_app!

on_worker_boot do
  # FastMcpPubsub automatically starts listener here
end
```

### Manual Control

```ruby
# Manually start/stop listener
FastMcpPubsub::Service.start_listener
FastMcpPubsub::Service.stop_listener

# Check listener status
FastMcpPubsub::Service.listener_thread&.alive?
```

## How It Works

1. **Patches FastMcp::Transports::RackTransport**: Overrides `send_message` method
2. **Broadcasts via PostgreSQL**: Uses `NOTIFY channel, payload` 
3. **Listener threads**: Each worker has a dedicated listener thread
4. **Local delivery**: Messages are delivered to local SSE clients in each worker

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `true` | Enable/disable PubSub functionality |
| `channel_name` | `'mcp_broadcast'` | PostgreSQL NOTIFY channel name |
| `auto_start` | `true` | Start listener automatically |
| `logger` | `Rails.logger` | Logger instance for debugging |
| `connection_pool_size` | `5` | Database connection pool size |

## Error Handling

- **Payload size limit**: 7800 bytes (PostgreSQL NOTIFY limit)
- **Fallback mechanism**: Falls back to local delivery if PubSub fails  
- **Automatic restart**: Listener restarts on connection errors
- **Graceful shutdown**: Proper cleanup on process exit

## Requirements

**This gem is an extension for Rails applications using FastMcp and requires:**

- **[FastMcp gem](https://github.com/yjacquin/fast-mcp)** ~> 1.5.0 (the base MCP server this gem extends)
- **Rails 7.0+** (required for Railtie integration)
- **PostgreSQL database** (for NOTIFY/LISTEN functionality)
- **Puma web server** in cluster mode (multi-worker setup)

**Important Notes**:
- This gem will not work in standalone Ruby applications or non-Rails frameworks, as it relies heavily on Rails infrastructure (ActiveRecord, Railtie, Rails.logger, etc.)
- **PostgreSQL is mandatory** - this gem will NOT work with MySQL, SQLite, or other databases as it requires PostgreSQL's NOTIFY/LISTEN functionality. Support for other databases would require significant additional development.

## Thread Safety

All operations are thread-safe and designed for multi-worker environments:

- Connection pooling for database operations
- Proper thread lifecycle management  
- Automatic cleanup on process termination

## Development

After checking out the repo, run:

```bash
bin/setup      # Install dependencies
rake test      # Run tests
bin/console    # Interactive prompt
```

To install locally:

```bash
bundle exec rake install
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jchsoft/fast_mcp_pubsub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).