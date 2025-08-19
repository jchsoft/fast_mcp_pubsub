# CLAUDE.md

This file provides guidance to Claude Code when working with the `fast_mcp_pubsub` gem.

## Gem Overview

FastMcp PubSub provides PostgreSQL NOTIFY/LISTEN clustering support for FastMcp RackTransport, enabling message broadcasting across multiple Puma workers in cluster mode.

## Code Conventions

### Code Quality
- Max 200 chars/line (soft limit - prefer readability over strict compliance)
  - breaking Ruby chain calls destroys the natural sentence flow and readability
- 14 lines/method, 110 lines/class
- Comments and tests in English
- KEEP CODE DRY (Don't Repeat Yourself)

### Ruby/Rails Philosophy
- **DO IT RUBY WAY OR RAILS WAY** - it's not Python, Java or PHP!
- Strong use of Ruby metaprogramming techniques
- code line should look like human sentence (e.g. `3.times do` not `for i in 0..2 do` - Ruby syntax reads like English)
- keep code raising exceptions when it's programmer's fault - DO NOT validate method parameters, expect them to be correct! Only validate user input
- do not repeat name of parameter in method name (e.g. `def create_new_user_from_user(user)` should be `def create_new_user_from(user)`)
- do not use extra variable if used only once - saves memory and reduces GC pressure under high traffic (e.g. `user = User.find(params[:id]); user.update(...)` should be `User.find(params[:id]).update(...)`) - use `.tap do` for chaining when you need to use the object later
- use metaprogramming instead of case statements (e.g. `self.send(method_name, params)` instead of `case method_name; when "find_slot"...` - let Ruby handle method dispatch and NoMethodError)
- PREFER FUNCTIONAL STYLE: use flat_map, map, select over loops and temp variables (e.g. `items.flat_map(&:children).uniq` not `results = []; items.each { |i| results.concat(i.children) }; results.uniq`)
- USE PATTERN MATCHING: Ruby 3.0+ `case/in` for complex conditionals instead of if/elsif chains - more expressive and catches unhandled cases
- ONE CLEAR RESPONSIBILITY: each method should do one thing well - if method has "and" in description, split it (e.g. `normalize_and_search` → `normalize` + `search`)
- FOLLOW KISS PRINCIPLE: Keep It Simple, Stupid - avoid unnecessary complexity, use simple solutions first
- ALWAYS TEST YOUR CODE

### Error Handling
- Use meaningful exception classes (not generic StandardError)
- Log errors with context using the configured logger
- Proper error propagation with fallback mechanisms
- Use `rescue_from` for common exceptions in Rails integration

### Performance Considerations
- Use database connection pooling efficiently
- Avoid blocking operations in main threads
- Cache expensive operations
- Monitor thread lifecycle and cleanup

### Thread Safety
- All operations must be thread-safe for cluster mode
- Use proper synchronization when accessing shared resources
- Handle thread lifecycle correctly (creation, monitoring, cleanup)
- Use connection checkout/checkin pattern for database operations

### Gem Specific Guidelines

#### Configuration
- Use configuration object pattern for all settings
- Provide sensible defaults that work out of the box
- Make all components configurable but not required
- Support both programmatic and initializer-based configuration

#### Rails Integration
- Use Railtie for automatic Rails integration
- Hook into appropriate Rails lifecycle events
- Respect Rails conventions for logging and error handling
- Provide manual configuration options for non-Rails usage

#### Error Recovery
- Implement automatic retry with backoff for transient errors
- Provide fallback mechanisms when PubSub fails
- Log errors appropriately without flooding logs
- Handle connection failures gracefully

#### Testing
- Test all public interfaces
- Mock external dependencies (PostgreSQL, FastMcp)
- Test error conditions and edge cases
- Provide test helpers for gem users
- Test both Rails and non-Rails usage

## Architecture

### Components

1. **FastMcpPubsub::Service** - Core PostgreSQL NOTIFY/LISTEN service
2. **FastMcpPubsub::Configuration** - Configuration management
3. **FastMcpPubsub::RackTransportPatch** - Monkey patch for FastMcp transport
4. **FastMcpPubsub::Railtie** - Rails integration and lifecycle management

### Message Flow

1. `RackTransport#send_message` → `FastMcpPubsub::Service.broadcast`
2. `Service.broadcast` → PostgreSQL NOTIFY
3. Each worker's listener thread receives NOTIFY
4. Listener calls `RackTransport#send_local_message` for local clients

### Thread Management

- One listener thread per worker process
- Thread cleanup on process exit
- Automatic restart on listener errors
- Connection pooling for database operations

## Dependencies

- **Rails** (>= 7.0) - Core framework integration
- **PostgreSQL** (via pg gem >= 1.0) - Database NOTIFY/LISTEN
- **ActiveRecord** - Connection pooling and database access
- **FastMcp** - The transport being patched (development/test dependency)

## Development

### Running Tests
```bash
bundle exec rake test
```

### Linting
```bash
bundle exec rubocop
```

### Console
```bash
bundle exec rake console
```

## WorkVector Task Access
- To read a task from WorkVector, use the workvector-production MCP server:
    1. Use `ListMcpResourcesTool` to get all available resources
    2. Load template using `ReadMcpResourceTool` with URI "template://task"
    3. Parse the task URL (e.g., https://workvector.com/jchsoft/tasks/8383) to extract account_code and task_id
    4. Load task content using the template with account_code and task_id parameters
- To log work progress, use `mcp__workvector-production__LogWorkProgressTool` with account_code, task_id, description and progress_percent. Log progress incrementally as you work on the task!
- **IMPORTANT**: Always set progress_percent to max 90% on first task completion - leave a few percent for potential follow-ups and adjustments