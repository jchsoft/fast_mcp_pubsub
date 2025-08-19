# frozen_string_literal: true

# Monkey patch for FastMcp::Transports::RackTransport
# Adds PostgreSQL PubSub support for cluster mode

module FastMcpPubsub
  # Lazy patch application - applies patch when FastMcp transport is first accessed
  module RackTransportPatch
    @patch_applied = false

    def self.apply_patch!
      return if @patch_applied
      return unless defined?(FastMcp::Transports::RackTransport)

      FastMcpPubsub.config.logger.debug "FastMcpPubsub: Patching FastMcp::Transports::RackTransport for PostgreSQL PubSub support"

      patch_transport_class
      @patch_applied = true
      FastMcpPubsub.config.logger.debug "FastMcpPubsub: RackTransport patch applied successfully"
    end

    def self.patch_transport_class
      FastMcp::Transports::RackTransport.class_eval do
        # Store reference to original method if not already done
        alias_method :send_local_message, :send_message unless method_defined?(:send_local_message)

        # Add running? method for identifying active instances (if not already present)
        define_method(:running?) { @running } unless method_defined?(:running?)

        # Override send_message for broadcast via PostgreSQL
        define_method(:send_message) do |message|
          if FastMcpPubsub.config.enabled
            broadcast_with_fallback(message)
          else
            send_local_message(message)
          end
        end

        # Helper method for broadcasting with fallback
        define_method(:broadcast_with_fallback) do |message|
          FastMcpPubsub.config.logger.debug "RackTransport: Broadcasting message via PostgreSQL PubSub"
          FastMcpPubsub::Service.broadcast(message)
        rescue StandardError => e
          FastMcpPubsub.config.logger.error "RackTransport: Error broadcasting message: #{e.message}"
          send_local_message(message)
        end
      end
    end

    def self.patch_applied?
      @patch_applied
    end
  end
end

# Try to apply patch immediately if FastMcp is already loaded
FastMcpPubsub::RackTransportPatch.apply_patch!
