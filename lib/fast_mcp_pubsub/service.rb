# frozen_string_literal: true

module FastMcpPubsub
  # Core PostgreSQL NOTIFY/LISTEN service for broadcasting MCP messages across Puma workers
  class Service
    MAX_PAYLOAD_SIZE = 7800 # PostgreSQL NOTIFY limit is 8000 bytes, leave some margin

    class << self
      attr_reader :listener_thread

      def broadcast(message)
        payload = message.to_json

        payload_too_large?(payload) ? send_error_response(message, payload) : send_payload(payload)
      rescue StandardError => e
        FastMcpPubsub.logger.error "FastMcpPubsub: Error broadcasting message: #{e.message}"
        raise
      end

      def start_listener
        return unless FastMcpPubsub.config.enabled
        return if @listener_thread&.alive?

        FastMcpPubsub.logger.info "FastMcpPubsub: Starting listener thread for PID #{Process.pid}"

        @listener_thread = Thread.new do
          Thread.current.name = "fast-mcp-pubsub-listener"
          listen_loop
        end

        # Register shutdown hook
        at_exit { stop_listener }
      end

      def stop_listener
        return unless @listener_thread&.alive?

        FastMcpPubsub.logger.info "FastMcpPubsub: Stopping listener thread for PID #{Process.pid}"
        @listener_thread.kill
        @listener_thread.join(5) # Wait max 5 seconds
        @listener_thread = nil
      end

      private

      def send_payload(payload)
        channel = FastMcpPubsub.config.channel_name
        FastMcpPubsub.logger.debug "FastMcpPubsub: Broadcasting message to #{channel}: #{payload.bytesize} bytes"

        ActiveRecord::Base.connection.execute(
          "NOTIFY #{channel}, #{ActiveRecord::Base.connection.quote(payload)}"
        )
      end

      def payload_too_large?(payload)
        payload.bytesize > MAX_PAYLOAD_SIZE
      end

      def send_error_response(message, payload)
        FastMcpPubsub.logger.error "FastMcpPubsub: Payload too large (#{payload.bytesize} bytes > #{MAX_PAYLOAD_SIZE} bytes)"

        error_message = {
          jsonrpc: "2.0",
          id: message[:id],
          error: {
            code: -32_001,
            message: "Response too large for PostgreSQL NOTIFY. Try requesting smaller page size."
          }
        }

        send_payload(error_message.to_json)
      end

      def listen_loop
        channel = FastMcpPubsub.config.channel_name

        begin
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            raw_conn = conn.raw_connection

            FastMcpPubsub.logger.info "FastMcpPubsub: Listening on #{channel} for PID #{Process.pid}"
            raw_conn.async_exec("LISTEN #{channel}")

            begin
              loop do
                raw_conn.wait_for_notify do |channel, pid, payload|
                  handle_notification(channel, pid, payload)
                end
              end
            ensure
              begin
                raw_conn.async_exec("UNLISTEN #{channel}")
              rescue StandardError => e
                FastMcpPubsub.logger.error "FastMcpPubsub: Error during UNLISTEN: #{e.message}"
              end
            end
          end
        rescue StandardError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Listener error: #{e.message}"
          FastMcpPubsub.logger.error e.backtrace.join("\n")

          # Restart after error
          sleep 1
          retry
        end
      end

      def handle_notification(_channel, pid, payload)
        FastMcpPubsub.logger.debug "FastMcpPubsub: Received notification from PID #{pid}: #{payload}"

        begin
          message = JSON.parse(payload)

          # Find active RackTransport instances and send to local clients
          if defined?(FastMcp::Transports::RackTransport)
            transports = transport_instances
            FastMcpPubsub.logger.debug "FastMcpPubsub: Found #{transports.size} transport instances"

            transports.each do |transport|
              FastMcpPubsub.logger.debug "FastMcpPubsub: Sending message to transport #{transport.object_id}"
              transport.send_local_message(message)
            end
          end
        rescue JSON::ParserError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Invalid JSON payload: #{e.message}"
        rescue StandardError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Error handling notification: #{e.message}"
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
end
