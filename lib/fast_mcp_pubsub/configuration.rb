# frozen_string_literal: true

module FastMcpPubsub
  # Configuration class for FastMcpPubsub gem settings
  class Configuration
    attr_accessor :enabled, :channel_name, :auto_start, :connection_pool_size, :sse_write_timeout

    def initialize
      @enabled = true
      @channel_name = "mcp_broadcast"
      @auto_start = true
      @connection_pool_size = 5
      # Seconds a write to one SSE client may block before that client counts as
      # gone; nil waits for TCP to give up. See AddressingPatch.apply_write_timeout.
      @sse_write_timeout = 10
    end
  end
end
