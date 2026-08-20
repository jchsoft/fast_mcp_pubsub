# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-08-20

### Fixed
- **A JSON-RPC response no longer reaches every connected SSE client.** Every
  response was published as a bare NOTIFY payload and then written into every
  entry of every worker's `@sse_clients`, so one client's answer landed in every
  other client's stream — across projects and across users. The only thing
  keeping clients apart was JSON-RPC id matching on the client side, which
  collides whenever two clients open fresh sessions at the same moment and both
  begin counting ids from 1. Observed in production as a runner installed for
  one project picking up a task belonging to another.
- `stop_listener` now clears `@listener_thread` when the thread has already died
  instead of leaving a dead reference behind, which callers read as "a listener
  is running".

### Added
- `FastMcpPubsub::CurrentClient` — thread-local record of which SSE client the
  request being served belongs to.
- `FastMcpPubsub::AddressingPatch` — the three pieces that carry FastMcp's
  `client_id` end to end: it is appended to the endpoint URL handed to the client
  on connect, captured from the client's POSTs, and used to deliver a response to
  that one client via the new `send_local_message_to`.
- `_pubsub_target` on the NOTIFY envelope, so every worker can tell whether a
  message is addressed to a client it holds.

### Compatibility
- A message with no target still fans out, so genuine notifications and clients
  that supply no id behave exactly as before.
- Bare, un-enveloped payloads from a worker still running an older gem are
  recognised and delivered, so a rolling restart does not drop messages.

## [1.3.3] - 2026-03-02

### Fixed
- The listener no longer starts under the test runner or a rake task. The
  Railtie checked `defined?(Puma)`, which is true whenever the gem is merely
  loaded; it now checks `Puma.cli_config`, so only a Puma actually launched via
  its CLI counts.
- `stop_listener` force-kills the listener thread after the five-second join,
  so a process can always exit even when `PG.connect` blocks during a reconnect.

## [1.3.2] - 2026-02-06

### Fixed
- Multi-worker race on database-stored payloads. `MessageStore` deleted the row
  as it read it, so of all the workers a NOTIFY woke, exactly one got the
  payload — and when that was a worker holding no SSE clients, the message was
  simply lost and the client timed out. Reading no longer deletes; the periodic
  cleanup handles removal. Cleanup also guards against a missing table.

## [1.3.1] - 2026-02-06

### Fixed
- Unix socket connections with peer authentication. Hardcoded host and port
  defaults forced a TCP connection; only the parameters actually present in the
  Rails config are passed to `PG.connect` now, so an absent host means the
  socket, as production expects.

## [1.3.0] - 2026-02-06

### Added
- Database overflow for responses larger than PostgreSQL NOTIFY's 8000-byte
  limit. Payloads under 7800 bytes still go straight down the channel; larger
  ones are stored via the new `MessageStore` and the NOTIFY carries a UUID
  reference. Stored rows are cleaned up roughly every 60 seconds by the listener.

## [1.2.0] - 2026-01-29

### Fixed
- "Lost synchronization with server" crashes during development hot-reload. The
  listener took its raw PostgreSQL connection from the ActiveRecord pool and so
  could share it with the main Rails thread. It now opens a dedicated connection
  outside the pool.

### Changed
- Shutdown is cooperative — a `@shutdown_requested` flag and a one-second
  `wait_for_notify` timeout instead of `Thread.kill` — and reloader hooks stop
  and restart the listener across a hot-reload.

## [1.1.0] - 2025-08-20

### Changed
- **Breaking.** Cluster mode is configured by hand: add
  `FastMcpPubsub::Service.start_listener` to your `on_worker_boot` hook. The
  automatic worker detection of 1.0.3–1.0.5 never became reliable and is gone;
  the Railtie now only keeps the listener out of the master process.

## [1.0.5] - 2025-08-20

### Fixed
- Worker detection reworked around an `after_initialize` callback, replacing the
  `Puma.cli_config` hook registration that did not fire dependably.

## [1.0.4] - 2025-08-20

### Fixed
- `NoMethodError` on Puma's `UserFileDefaultOptions`, which has no `dig`.

## [1.0.3] - 2025-08-20

### Fixed
- The listener started in the master process rather than the workers. Cluster
  mode is detected and worker boot hooks registered so it starts only in a
  worker.

## [1.0.2] - 2025-08-20

### Changed
- Extensive debug logging around listener startup, added to diagnose workers
  that never began listening in production cluster mode.

## [1.0.1] - 2025-08-20

### Fixed
- No messages reached SSE clients in production. `transport_instances` filtered
  on `running?`, which production transports never set, so the list came back
  empty. The filter is gone.

## [1.0.0] - 2025-08-19

### Added
- Initial implementation of PostgreSQL NOTIFY/LISTEN clustering for FastMcp RackTransport
- FastMcpPubsub::Service for message broadcasting and listening
- FastMcpPubsub::Configuration for configurable settings (enabled, channel_name, auto_start, connection_pool_size)
- RackTransport monkey patch for cluster mode message distribution
- Rails Railtie for automatic initialization and Rails integration
- Puma cluster mode integration with automatic worker hooks
- Payload size validation (7800 bytes limit) with fallback error responses
- Thread-safe listener management with automatic restart on errors
- Comprehensive logging via FastMcpPubsub.logger (Rails.logger)
- Connection pooling for database operations
- Automatic patch application during Rails initialization
- Method redefinition protection to avoid warnings
- Full test coverage (18 tests, 33 assertions)
- RuboCop compliance (0 offenses)

### Implementation Details
- **Automatic Integration**: No manual configuration required - just add to Gemfile
- **Smart Timing**: Patch applied after Rails initializers load via `after: :load_config_initializers`
- **Dual Mode Support**: Works in both single-worker and cluster mode
- **Clean Logging**: Simplified logging without complex conditional checks
- **Warning-Free**: Eliminated method redefinition warnings using proper mocking patterns
- **Robust Error Handling**: Fallback to local delivery if PostgreSQL NOTIFY fails
- **Rails-Specific**: Designed for Rails applications with ActiveRecord and PostgreSQL

### Technical Architecture
- **Patch Strategy**: Monkey patches `FastMcp::Transports::RackTransport#send_message`
- **Broadcasting**: Uses PostgreSQL NOTIFY/LISTEN for inter-worker communication  
- **Listener Management**: Dedicated thread per worker with automatic lifecycle management
- **Configuration**: Simple configuration object with sensible defaults
- **Integration**: Rails Railtie for seamless Rails integration