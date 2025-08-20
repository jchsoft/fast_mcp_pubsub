# frozen_string_literal: true

require_relative "fast_mcp_pubsub/version"
require_relative "fast_mcp_pubsub/configuration"
require_relative "fast_mcp_pubsub/service"

# PostgreSQL NOTIFY/LISTEN clustering support for FastMcp RackTransport.
# Enables FastMcp RackTransport to work in cluster mode by broadcasting messages
# via PostgreSQL NOTIFY/LISTEN across multiple Puma workers.
module FastMcpPubsub
  class Error < StandardError; end

  class << self
    attr_accessor :configuration
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration)
  end

  def self.config
    self.configuration ||= Configuration.new
  end

  # Simple logging helper - uses Rails.logger since this gem is Rails-specific
  def self.logger
    Rails.logger
  end

  # Register Puma worker boot hook for cluster mode
  def self.register_worker_boot_hook
    if defined?(Puma.cli_config)
      logger.info "FastMcpPubsub: Registering Puma worker boot hook"

      # Use Puma's built-in worker boot hook
      Puma.cli_config&.options&.fetch(:on_worker_boot, [])&.push(proc do
        logger.info "FastMcpPubsub: Worker boot hook executing for PID #{Process.pid}"
        Service.start_listener if config.enabled && config.auto_start
      end)
    else
      logger.warn "FastMcpPubsub: Could not register worker boot hook - Puma not available"
    end
  end
end

# Load patch after module is fully defined
require_relative "fast_mcp_pubsub/rack_transport_patch"
require_relative "fast_mcp_pubsub/railtie" if defined?(Rails)
