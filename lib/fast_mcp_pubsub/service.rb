# frozen_string_literal: true

module FastMcpPubsub
  # Core PostgreSQL NOTIFY/LISTEN service for broadcasting MCP messages across Puma workers
  class Service
    MAX_PAYLOAD_SIZE = 7800 # PostgreSQL NOTIFY limit is 8000 bytes, leave some margin

    class << self
      attr_reader :listener_thread

      def broadcast(message)
        payload = message.to_json

        if payload_too_large?(payload)
          send_error_response(message)
        else
          send_payload(payload)
        end
      rescue StandardError => e
        if FastMcpPubsub.config&.logger
          FastMcpPubsub.config.logger.error "FastMcpPubsub: Error broadcasting message: #{e.message}"
        end
        raise
      end

      def start_listener
        return unless FastMcpPubsub.config.enabled
        return if @listener_thread&.alive?

        if FastMcpPubsub.config&.logger
          FastMcpPubsub.config.logger.info "FastMcpPubsub: Starting listener thread for PID #{Process.pid}"
        elsif defined?(Rails) && Rails.logger
          Rails.logger.info "FastMcpPubsub: Starting listener thread for PID #{Process.pid}"
        end

        @listener_thread = Thread.new do
          Thread.current.name = "fast-mcp-pubsub-listener"
          listen_loop
        end

        # Register shutdown hook
        at_exit { stop_listener }
      end

      def stop_listener
        return unless @listener_thread&.alive?

        if FastMcpPubsub.config&.logger
          FastMcpPubsub.config.logger.info "FastMcpPubsub: Stopping listener thread for PID #{Process.pid}"
        end
        @listener_thread.kill
        @listener_thread.join(5) # Wait max 5 seconds
        @listener_thread = nil
      end

      private

      def send_payload(payload)
        channel = FastMcpPubsub.config.channel_name
        if FastMcpPubsub.config&.logger
          FastMcpPubsub.config.logger.debug "FastMcpPubsub: Broadcasting message to #{channel}: #{payload.bytesize} bytes"
        end

        ActiveRecord::Base.connection.execute(
          "NOTIFY #{channel}, #{ActiveRecord::Base.connection.quote(payload)}"
        )
      end

      def payload_too_large?(payload)
        payload.bytesize > MAX_PAYLOAD_SIZE
      end

      def send_error_response(message)
        if FastMcpPubsub.config&.logger
          FastMcpPubsub.config.logger.error "FastMcpPubsub: Payload too large (#{message.to_json.bytesize} bytes > #{MAX_PAYLOAD_SIZE} bytes)"
        end

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
        conn = nil
        channel = FastMcpPubsub.config.channel_name

        begin
          conn = ActiveRecord::Base.connection_pool.checkout
          raw_conn = conn.raw_connection

          if FastMcpPubsub.config&.logger
            FastMcpPubsub.config.logger.info "FastMcpPubsub: Listening on #{channel} for PID #{Process.pid}"
          elsif defined?(Rails) && Rails.logger
            Rails.logger.info "FastMcpPubsub: Listening on #{channel} for PID #{Process.pid}"
          end
          raw_conn.async_exec("LISTEN #{channel}")

          loop do
            raw_conn.wait_for_notify do |channel, pid, payload|
              handle_notification(channel, pid, payload)
            end
          end
        rescue StandardError => e
          if FastMcpPubsub.config&.logger
            FastMcpPubsub.config.logger.error "FastMcpPubsub: Listener error: #{e.message}"
            FastMcpPubsub.config.logger.error e.backtrace.join("\n")
          end

          # Restart after error
          sleep 1
          retry
        ensure
          if conn
            begin
              conn.raw_connection.async_exec("UNLISTEN #{channel}")
            rescue StandardError => e
              if FastMcpPubsub.config&.logger
                FastMcpPubsub.config.logger.error "FastMcpPubsub: Error during UNLISTEN: #{e.message}"
              end
            end
            ActiveRecord::Base.connection_pool.checkin(conn)
          end
        end
      end

      def handle_notification(_channel, pid, payload)
        if FastMcpPubsub.config&.logger
          FastMcpPubsub.config.logger.debug "FastMcpPubsub: Received notification from PID #{pid}: #{payload}"
        end

        begin
          message = JSON.parse(payload)

          # Find active RackTransport instances and send to local clients
          if defined?(FastMcp::Transports::RackTransport)
            transport_instances.each do |transport|
              transport.send_local_message(message)
            end
          end
        rescue JSON::ParserError => e
          if FastMcpPubsub.config&.logger
            FastMcpPubsub.config.logger.error "FastMcpPubsub: Invalid JSON payload: #{e.message}"
          end
        rescue StandardError => e
          if FastMcpPubsub.config&.logger
            FastMcpPubsub.config.logger.error "FastMcpPubsub: Error handling notification: #{e.message}"
          end
        end
      end

      def transport_instances
        # Find all active RackTransport instances
        # This is a bit of a hack, but it works for our use case
        ObjectSpace.each_object(FastMcp::Transports::RackTransport).select(&:running?)
      rescue StandardError
        []
      end
    end
  end
end
