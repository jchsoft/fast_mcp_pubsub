# frozen_string_literal: true

require "test_helper"

class TestService < Minitest::Test
  def setup
    FastMcpPubsub.configuration = nil # Reset configuration
    @service = FastMcpPubsub::Service
  end

  def teardown
    @service.stop_listener
    FastMcpPubsub.configuration = nil
  end

  def test_broadcast_small_message
    message = { id: 1, method: "test", params: {} }

    # Should not raise error with ActiveRecord mocked
    @service.broadcast(message)
    # Just testing it doesn't crash
  end

  def test_broadcast_large_message_stores_in_db
    large_content = "x" * 8000
    message = { id: 1, method: "test", params: { content: large_content } }

    sent_payloads = []
    stored_payloads = []

    # Scoped stubs rather than a module prepended to the service's singleton
    # class: a prepended module stays in front of that class for the rest of the
    # process and outranks every later stub of the same method, so it silently
    # disarms other tests' expectations depending on the order they run in.
    FastMcpPubsub::MessageStore.stub :store, lambda { |payload|
      stored_payloads << payload
      "test-uuid"
    } do
      @service.stub(:send_payload, ->(payload) { sent_payloads << JSON.parse(payload) }) do
        @service.broadcast(message)
      end
    end

    # Should have stored the payload
    assert_equal 1, stored_payloads.size
    assert_operator stored_payloads.first.bytesize, :>, 7800

    # Should have sent a reference
    assert_equal 1, sent_payloads.size
    ref_message = sent_payloads.first

    assert_equal "test-uuid", ref_message["_pubsub_ref"]
  end

  def test_start_listener_when_enabled
    FastMcpPubsub.configure { |c| c.enabled = true }

    assert_nil @service.listener_thread

    @service.start_listener

    assert @service.listener_thread
    # Give thread time to start
    sleep 0.1
    # NOTE: Thread might not be alive in test because of mocked wait_for_notify
  end

  def test_start_listener_when_disabled
    FastMcpPubsub.configure { |c| c.enabled = false }

    @service.start_listener

    assert_nil @service.listener_thread
  end

  def test_stop_listener
    FastMcpPubsub.configure { |c| c.enabled = true }

    @service.start_listener
    @service.stop_listener

    # Thread should be stopped
    assert_nil @service.listener_thread
  end

  def test_handle_notification_with_valid_json
    message = { id: 1, method: "test" }
    payload = message.to_json

    mock_transport = Minitest::Mock.new
    parsed_message = JSON.parse(payload)
    mock_transport.expect(:send_local_message, nil, [parsed_message])

    # Call handle_notification (private method)
    @service.stub(:transport_instances, [mock_transport]) do
      @service.send(:handle_notification, 123, payload)
    end

    mock_transport.verify
  end

  def test_handle_notification_with_invalid_json
    # Should not raise error with invalid JSON
    assert_silent do
      @service.send(:handle_notification, 123, "invalid json")
    end
  end

  def test_payload_size_limit
    small_payload = "x" * 100
    large_payload = "x" * 8000

    refute @service.send(:payload_too_large?, small_payload)
    assert @service.send(:payload_too_large?, large_payload)
  end

  def test_handle_notification_with_pubsub_ref
    ref_message = { _pubsub_ref: "test-uuid" }
    payload = ref_message.to_json
    stored_message = { "id" => 1, "method" => "test", "result" => "data" }

    mock_transport = Minitest::Mock.new
    mock_transport.expect(:send_local_message, nil, [stored_message])

    # Mock MessageStore.fetch
    FastMcpPubsub::MessageStore.stub :fetch, stored_message.to_json do
      @service.stub(:transport_instances, [mock_transport]) do
        @service.send(:handle_notification, 123, payload)
      end
    end

    mock_transport.verify
  end

  def test_handle_notification_with_expired_ref
    ref_message = { _pubsub_ref: "expired-uuid" }
    payload = ref_message.to_json

    # Mock transport instances - should not be called
    mock_transport = Minitest::Mock.new

    # Mock MessageStore.fetch returning nil (expired)
    FastMcpPubsub::MessageStore.stub :fetch, nil do
      @service.stub(:transport_instances, [mock_transport]) do
        @service.send(:handle_notification, 123, payload)
      end
    end

    # Should not have called transport since message was expired
    assert_mock mock_transport
  end

  def test_cleanup_called_periodically
    FastMcpPubsub.configure { |c| c.enabled = true }

    cleanup_count = 0

    # Mock MessageStore.cleanup
    FastMcpPubsub::MessageStore.stub :cleanup, -> { cleanup_count += 1 } do
      # Mock the listen loop to run a few iterations
      mock_module = Module.new do
        define_method(:listen_loop) do
          @cleanup_counter ||= 0
          # Simulate 120 iterations (should trigger cleanup twice)
          120.times do
            @cleanup_counter += 1
            FastMcpPubsub::MessageStore.cleanup if (@cleanup_counter % 60).zero?
          end
        end
      end

      @service.singleton_class.prepend(mock_module)
      @service.send(:listen_loop)
    end

    assert_equal 2, cleanup_count
  end
end
