# frozen_string_literal: true

require "test_helper"

class TestFastMcpPubsub < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::FastMcpPubsub::VERSION
  end

  def test_configuration_default_values
    config = FastMcpPubsub::Configuration.new

    assert config.enabled
    assert_equal "mcp_broadcast", config.channel_name
    assert config.auto_start
    assert_equal 5, config.connection_pool_size
  end

  def test_configure_method
    FastMcpPubsub.configure do |config|
      config.enabled = false
      config.channel_name = "test_channel"
      config.auto_start = false
    end

    refute FastMcpPubsub.config.enabled
    assert_equal "test_channel", FastMcpPubsub.config.channel_name
    refute FastMcpPubsub.config.auto_start

    # Reset to defaults for other tests
    FastMcpPubsub.configuration = nil
  end

  def test_config_method_returns_default_configuration
    FastMcpPubsub.configuration = nil
    config = FastMcpPubsub.config

    assert_instance_of FastMcpPubsub::Configuration, config
    assert config.enabled
  end

  def test_logger_returns_rails_logger
    assert_equal Rails.logger, FastMcpPubsub.logger
  end
end
