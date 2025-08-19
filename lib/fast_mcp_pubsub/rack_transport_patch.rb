# frozen_string_literal: true

# Monkey patch for FastMcp::Transports::RackTransport
# Adds PostgreSQL PubSub support for cluster mode

module FastMcpPubsub
  # Lazy patch application - applies patch when FastMcp transport is first accessed
  module RackTransportPatch
    @patch_applied = false

    def self.apply_patch!
      if @patch_applied
        log_debug "FastMcpPubsub: RackTransport patch already applied, skipping"
        return
      end

      unless defined?(FastMcp::Transports::RackTransport)
        log_debug "FastMcpPubsub: FastMcp::Transports::RackTransport not defined yet, skipping patch"
        return
      end

      log_info "FastMcpPubsub: Patching FastMcp::Transports::RackTransport for PostgreSQL PubSub support"

      patch_transport_class
      @patch_applied = true
      log_info "FastMcpPubsub: RackTransport patch applied successfully"
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
          if FastMcpPubsub.config&.logger
            FastMcpPubsub.config.logger.debug "RackTransport: Broadcasting message via PostgreSQL PubSub"
          end
          FastMcpPubsub::Service.broadcast(message)
        rescue StandardError => e
          if FastMcpPubsub.config&.logger
            FastMcpPubsub.config.logger.error "RackTransport: Error broadcasting message: #{e.message}"
          end
          send_local_message(message)
        end
      end
    end

    def self.patch_applied?
      @patch_applied
    end

    private

    def self.log_info(message)
      if FastMcpPubsub.config&.logger
        FastMcpPubsub.config.logger.info message
      else
        puts message
      end
    end

    def self.log_debug(message)
      if FastMcpPubsub.config&.logger
        FastMcpPubsub.config.logger.debug message
      else
        puts message if ENV['DEBUG']
      end
    end
  end
end

# Note: Patch is automatically applied by Railtie initializer when Rails loads
