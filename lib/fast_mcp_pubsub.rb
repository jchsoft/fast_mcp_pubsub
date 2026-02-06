# frozen_string_literal: true

require_relative "fast_mcp_pubsub/version"
require_relative "fast_mcp_pubsub/configuration"
require_relative "fast_mcp_pubsub/message_store"
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
end

# Load patch after module is fully defined
require_relative "fast_mcp_pubsub/rack_transport_patch"
require_relative "fast_mcp_pubsub/railtie" if defined?(Rails)
