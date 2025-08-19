# frozen_string_literal: true

module FastMcpPubsub
  class Configuration
    attr_accessor :enabled, :channel_name, :auto_start, :logger, :connection_pool_size

    def initialize
      @enabled = true
      @channel_name = 'mcp_broadcast'
      @auto_start = true
      @logger = defined?(Rails) ? Rails.logger : Logger.new($stdout)
      @connection_pool_size = 5
    end
  end
end