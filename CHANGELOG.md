# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial implementation of PostgreSQL NOTIFY/LISTEN clustering for FastMcp RackTransport
- FastMcpPubsub::Service for message broadcasting and listening
- FastMcpPubsub::Configuration for configurable settings
- RackTransport monkey patch for cluster mode message distribution
- Rails Railtie for automatic initialization
- Puma cluster mode integration
- Payload size validation with fallback error responses
- Thread-safe listener management with automatic restart
- Comprehensive logging and error handling
- Connection pooling for database operations

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- N/A (initial release)