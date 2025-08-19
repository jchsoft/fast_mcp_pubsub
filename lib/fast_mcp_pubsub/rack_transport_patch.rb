# frozen_string_literal: true

# Monkey patch for FastMcp::Transports::RackTransport
# Adds PostgreSQL PubSub support for cluster mode

# Apply patch when FastMcp is available and gem is enabled
if defined?(FastMcp::Transports::RackTransport)
  module FastMcp
    module Transports
      class RackTransport
        # Alias original method for local sending
        alias send_local_message send_message

        # Add running? method for identifying active instances
        def running?
          @running
        end

        # Override send_message for broadcast via PostgreSQL
        def send_message(message)
          # Check if PubSub is enabled at runtime
          if FastMcpPubsub.config.enabled
            FastMcpPubsub.config.logger.debug "RackTransport: Broadcasting message via PostgreSQL PubSub"

            begin
              # Broadcast via PostgreSQL NOTIFY
              FastMcpPubsub::Service.broadcast(message)
            rescue StandardError => e
              FastMcpPubsub.config.logger.error "RackTransport: Error broadcasting message: #{e.message}"
              # Fallback to local sending if PubSub fails
              send_local_message(message)
            end
          else
            # PubSub disabled, use local sending
            send_local_message(message)
          end
        end
      end
    end
  end
end
