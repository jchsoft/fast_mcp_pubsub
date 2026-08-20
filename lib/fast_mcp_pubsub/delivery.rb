# frozen_string_literal: true

module FastMcpPubsub
  # What a worker does with a message that arrives on the channel.
  #
  # Every worker receives every NOTIFY, so this is where a message is matched to
  # the clients it is actually for: an addressed one reaches the single client
  # that asked, and only on the worker holding it, while an unaddressed one — a
  # genuine notification — still fans out. See AddressingPatch for how the target
  # gets onto the envelope in the first place.
  module Delivery
    private

    def handle_notification(pid, payload)
      FastMcpPubsub.logger.debug "FastMcpPubsub: Received notification from PID #{pid}: #{payload}"

      begin
        envelope = JSON.parse(payload)
        message = unwrap(envelope)
        return unless message # Reference already expired

        deliver_to_transports(message, target_of(envelope))
      rescue JSON::ParserError => e
        FastMcpPubsub.logger.error "FastMcpPubsub: Invalid JSON payload: #{e.message}"
      rescue StandardError => e
        FastMcpPubsub.logger.error "FastMcpPubsub: Error handling notification: #{e.message}"
      end
    end

    # The client this message is addressed to, or nil for a fan-out.
    def target_of(envelope)
      envelope["_pubsub_target"] if envelope.is_a?(Hash)
    end

    # Unwraps the three shapes that arrive on the channel: an inline message, a
    # database reference for one too large to fit in a NOTIFY, and a bare
    # JSON-RPC message with no envelope at all — which is what a worker still
    # running an older gem publishes during a rolling restart.
    def unwrap(envelope)
      return envelope unless envelope.is_a?(Hash)
      return envelope["_pubsub_message"] if envelope.key?("_pubsub_message")
      return envelope unless envelope.key?("_pubsub_ref")

      stored_payload = MessageStore.fetch(envelope["_pubsub_ref"])
      stored_payload && JSON.parse(stored_payload)
    end

    def deliver_to_transports(message, client_id = nil)
      # Find active RackTransport instances and send to local clients
      return unless defined?(FastMcp::Transports::RackTransport)

      transports = transport_instances
      FastMcpPubsub.logger.debug "FastMcpPubsub: Found #{transports.size} transport instances"

      transports.each do |transport|
        FastMcpPubsub.logger.debug "FastMcpPubsub: Sending message to transport #{transport.object_id}"
        next transport.send_local_message_to(client_id, message) if client_id

        transport.send_local_message(message)
      end
    end

    def transport_instances
      # Find all RackTransport instances - don't filter by running? since it's not reliably implemented
      ObjectSpace.each_object(FastMcp::Transports::RackTransport).to_a
    rescue StandardError
      []
    end
  end
end
