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

### Automatic Integration

**No configuration needed!** Just add the gem to your Gemfile and it works automatically.

The gem will:
- ✅ **Automatically patch** FastMcp::Transports::RackTransport during Rails initialization
- ✅ **Start listener** automatically when Rails server starts
- ✅ **Use Rails.logger** for logging (no configuration required)
- ✅ **Work in both** single-worker and cluster mode

### Optional Configuration

If you need custom settings:

```ruby
# config/initializers/fast_mcp_pubsub.rb (optional)
FastMcpPubsub.configure do |config|
  config.enabled = Rails.env.production?    # Enable only in production
  config.channel_name = 'my_custom_channel' # Custom PostgreSQL NOTIFY channel
  config.auto_start = true                  # Start listener automatically (default: true)
  config.connection_pool_size = 10          # Database connection pool size
end
```

### Puma Cluster Mode

For cluster mode (multiple workers), you need to manually start the listener in each worker process:

```ruby
# config/puma/production.rb
workers ENV.fetch("WEB_CONCURRENCY") { 2 }
preload_app!

on_worker_boot do
  Rails.logger.info "MCP Transport: Starting PubSub listener for cluster mode worker #{Process.pid}"
  
  # Start FastMcpPubsub listener in each worker
  FastMcpPubsub::Service.start_listener
  
  # Your other worker boot code...
end
```

**Why manual setup is required:**
- 🔧 **Master process** automatically detects cluster mode and skips listener startup  
- 👷 **Worker processes** need explicit listener startup in `on_worker_boot` hook
- 📡 **Each worker** gets its own listener thread for receiving broadcasts
- 🔄 **Automatic cleanup** happens on worker shutdown

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

### Addressing

A JSON-RPC **response** is delivered only to the client that asked for it; a
**notification** still reaches everyone. FastMcp answers over SSE and writes each
message to every open stream, so without addressing one client's response lands
in every other client's session — and the only thing separating them is
JSON-RPC id matching, which collides as soon as two clients open fresh sessions
at the same moment and both start counting ids from 1.

The gem closes that by carrying FastMcp's own `client_id` end to end:

- the endpoint URL handed to a client on connect carries its `client_id`
- the client's POSTs come back with it, and it is held in `CurrentClient` for the
  length of the request
- `send_message` stamps it onto the NOTIFY envelope as `_pubsub_target`
- each worker delivers a targeted message only to that client, and ignores one
  addressed to a client another worker holds

A message with no target — a genuine notification, or a request from a client
that supplied no id — falls back to the previous fan-out, so older clients keep
working.

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `true` | Enable/disable PubSub functionality |
| `channel_name` | `'mcp_broadcast'` | PostgreSQL NOTIFY channel name |
| `auto_start` | `true` | Start listener automatically |
| `connection_pool_size` | `5` | Database connection pool size |

**Note**: Logging is handled automatically via `FastMcpPubsub.logger` which returns `Rails.logger`.

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