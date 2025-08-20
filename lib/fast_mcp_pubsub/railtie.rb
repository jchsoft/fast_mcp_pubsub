# frozen_string_literal: true

module FastMcpPubsub
  # Rails integration for automatic FastMcpPubsub setup and Puma cluster mode hooks
  class Railtie < Rails::Railtie
    # Start listener when Rails is ready
    initializer "fast_mcp_pubsub.start_listener" do |app|
      railtie = self
      app.config.to_prepare do
        # Non-cluster mode initialization (rails server)
        # Only start if we're in a web server environment
        Rails.logger.info "FastMcpPubsub: Checking listener startup conditions - cluster_mode: #{railtie.send(:cluster_mode?)}, should_start: #{railtie.send(:should_start_listener?)}"

        if railtie.send(:should_start_listener?)
          Rails.logger.info "FastMcpPubsub: Starting listener for non-cluster mode"
          FastMcpPubsub::Service.start_listener
          railtie.instance_variable_set(:@listener_started, true)
        else
          Rails.logger.info "FastMcpPubsub: Not starting listener in master process (cluster mode detected or conditions not met)"
        end
      end
    end

    # Apply patch to FastMcp::Transports::RackTransport after all initializers are loaded
    initializer "fast_mcp_pubsub.apply_patch", after: :load_config_initializers do
      FastMcpPubsub.logger.debug "FastMcpPubsub: Attempting to apply RackTransport patch"
      FastMcpPubsub::RackTransportPatch.apply_patch!
    end

    # Worker process listener startup
    initializer "fast_mcp_pubsub.worker_listener", after: :load_config_initializers do
      FastMcpPubsub.logger.info "FastMcpPubsub: Worker listener initializer - enabled: #{FastMcpPubsub.config.enabled}, auto_start: #{FastMcpPubsub.config.auto_start}"

      # Start listener in worker processes after app is fully loaded
      Rails.application.config.after_initialize do
        if FastMcpPubsub.config.enabled && FastMcpPubsub.config.auto_start && worker_process?
          FastMcpPubsub.logger.info "FastMcpPubsub: Starting listener in worker process PID #{Process.pid}"
          FastMcpPubsub::Service.start_listener
        elsif worker_process?
          FastMcpPubsub.logger.info "FastMcpPubsub: Worker process detected but listener startup skipped - enabled: #{FastMcpPubsub.config.enabled}, auto_start: #{FastMcpPubsub.config.auto_start}"
        end
      end
    end

    private

    def should_start_listener?
      web_server_environment? &&
        !cluster_mode? &&
        FastMcpPubsub.config.enabled &&
        FastMcpPubsub.config.auto_start &&
        !instance_variable_get(:@listener_started)
    end

    def web_server_environment?
      Rails.const_defined?("Server") || defined?(Puma) || ENV["MCP_SERVER_AUTO_START"] == "true"
    end

    def cluster_mode?
      # Check if Puma is running in cluster mode (multiple workers)
      defined?(Puma.cli_config) &&
        Puma.cli_config&.options&.[](:workers).to_i > 1
    end

    def worker_process?
      # Simple heuristic: if we're in cluster mode and after_initialize runs,
      # and there's no listener running yet, we're probably in a worker
      cluster_mode? && !FastMcpPubsub::Service.listener_thread&.alive?
    end
  end
end
