# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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