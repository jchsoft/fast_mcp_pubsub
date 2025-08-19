# frozen_string_literal: true

# Monkey patch for FastMcp::Transports::RackTransport
# Adds PostgreSQL PubSub support for cluster mode

module FastMcpPubsub
  # Lazy patch application - applies patch when FastMcp transport is first accessed
  module RackTransportPatch
    @patch_applied = false

    def self.apply_patch!
      if @patch_applied
        FastMcpPubsub.logger.debug "FastMcpPubsub: RackTransport patch already applied, skipping"
        return
      end

      unless defined?(FastMcp::Transports::RackTransport)
        FastMcpPubsub.logger.debug "FastMcpPubsub: FastMcp::Transports::RackTransport not defined yet, skipping patch"
        return
      end

      FastMcpPubsub.logger.info "FastMcpPubsub: Patching FastMcp::Transports::RackTransport for PostgreSQL PubSub support"

      patch_transport_class
      @patch_applied = true
      FastMcpPubsub.logger.info "FastMcpPubsub: RackTransport patch applied successfully"
    end

    def self.patch_transport_class
      add_basic_methods
      add_send_message_override
      add_fallback_method
    end

    def self.add_basic_methods
      FastMcp::Transports::RackTransport.class_eval do
        alias_method :send_local_message, :send_message unless method_defined?(:send_local_message)
        define_method(:running?) { @running } unless method_defined?(:running?)
      end
    end

    def self.add_send_message_override
      FastMcp::Transports::RackTransport.class_eval do
        return if method_defined?(:send_message_with_pubsub)

        alias_method :send_message_original, :send_message if method_defined?(:send_message)

        define_method(:send_message) do |message|
          FastMcpPubsub.config.enabled ? broadcast_with_fallback(message) : send_local_message(message)
        end

        alias_method :send_message_with_pubsub, :send_message
      end
    end

    def self.add_fallback_method
      FastMcp::Transports::RackTransport.class_eval do
        return if method_defined?(:broadcast_with_fallback)

        define_method(:broadcast_with_fallback) do |message|
          FastMcpPubsub.logger.debug "RackTransport: Broadcasting message via PostgreSQL PubSub"
          FastMcpPubsub::Service.broadcast(message)
        rescue StandardError => e
          FastMcpPubsub.logger.error "RackTransport: Error broadcasting message: #{e.message}"
          send_local_message(message)
        end
      end
    end

    def self.patch_applied?
      @patch_applied
    end
  end
end

# NOTE: Patch is automatically applied by Railtie initializer when Rails loads
