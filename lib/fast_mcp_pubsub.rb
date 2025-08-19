# frozen_string_literal: true

require_relative "fast_mcp_pubsub/version"
require_relative "fast_mcp_pubsub/configuration"
require_relative "fast_mcp_pubsub/service"
require_relative "fast_mcp_pubsub/rack_transport_patch"
require_relative "fast_mcp_pubsub/railtie" if defined?(Rails)

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
end
