# frozen_string_literal: true

module FastMcpPubsub
  class Railtie < Rails::Railtie
    initializer "fast_mcp_pubsub.configure" do |app|
      # Non-cluster mode initialization (rails server)
      if Rails.const_defined?('Server')
        app.config.after_initialize do
          if FastMcpPubsub.config.enabled && FastMcpPubsub.config.auto_start
            FastMcpPubsub.config.logger.info "FastMcpPubsub: Starting listener for non-cluster mode"
            FastMcpPubsub::Service.start_listener
          end
        end
      end
    end

    # Puma worker boot hook for cluster mode
    initializer "fast_mcp_pubsub.puma_integration" do
      if defined?(Puma) && FastMcpPubsub.config.enabled
        # Register the listener to start on worker boot
        Puma::Runner.class_eval do
          alias_method :original_load_and_bind, :load_and_bind
          
          def load_and_bind
            result = original_load_and_bind
            
            # Add our worker boot hook
            if @config.options[:workers] && @config.options[:workers] > 1
              @config.on_worker_boot do
                if FastMcpPubsub.config.auto_start
                  FastMcpPubsub.config.logger.info "FastMcpPubsub: Starting PubSub listener for cluster mode worker #{Process.pid}"
                  FastMcpPubsub::Service.start_listener
                end
              end
            end
            
            result
          end
        end
      end
    end
  end
end