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

    # NOTE: For cluster mode, add FastMcpPubsub::Service.start_listener to your
    # on_worker_boot hook in config/puma/production.rb

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
  end
end
