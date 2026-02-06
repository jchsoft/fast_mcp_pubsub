# frozen_string_literal: true

require "test_helper"

class TestMessageStore < Minitest::Test
  def setup
    @message_store = FastMcpPubsub::MessageStore
    # Reset cached state
    @message_store.instance_variable_set(:@table_exists, false)
  end

  def test_store_returns_uuid
    payload = '{"test":"data"}'

    # Mock ensure_table_exists to do nothing
    @message_store.stub :ensure_table_exists, nil do
      # Mock the database operations
      mock_execute = Minitest::Mock.new
      mock_execute.expect(:call, nil, [String])

      ActiveRecord::Base.connection.stub :execute, mock_execute do
        result = @message_store.store(payload)

        # Should return a UUID
        assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, result)
      end

      mock_execute.verify
    end
  end

  def test_fetch_and_delete_returns_payload
    test_uuid = "test-uuid-123"
    expected_payload = '{"test":"data"}'

    # Mock select_value to return payload
    ActiveRecord::Base.connection.stub :select_value, expected_payload do
      result = @message_store.fetch_and_delete(test_uuid)

      assert_equal expected_payload, result
    end
  end

  def test_fetch_and_delete_returns_nil_for_missing
    test_uuid = "missing-uuid"

    # Mock select_value to return nil
    ActiveRecord::Base.connection.stub :select_value, nil do
      result = @message_store.fetch_and_delete(test_uuid)

      assert_nil result
    end
  end

  def test_ensure_table_exists_creates_table
    # Mock table_exists? to return false, then true
    table_exists_calls = 0
    mock_table_exists = lambda do |_name|
      table_exists_calls += 1
      false
    end

    mock_execute = Minitest::Mock.new
    mock_execute.expect(:call, nil, [String])

    ActiveRecord::Base.connection.stub :table_exists?, mock_table_exists do
      ActiveRecord::Base.connection.stub :execute, mock_execute do
        @message_store.ensure_table_exists
      end
    end

    mock_execute.verify
  end

  def test_ensure_table_exists_skips_if_cached
    # Set cached flag
    @message_store.instance_variable_set(:@table_exists, true)

    # Should not call table_exists? or execute
    ActiveRecord::Base.connection.stub :table_exists?, ->(_) { raise "Should not be called" } do
      ActiveRecord::Base.connection.stub :execute, ->(_) { raise "Should not be called" } do
        # If we get here without raising, the cache worked
        @message_store.ensure_table_exists
      end
    end
  end

  def test_cleanup
    older_than = Time.now - 300

    mock_execute = Minitest::Mock.new
    mock_execute.expect(:call, nil, [String])

    ActiveRecord::Base.connection.stub :execute, mock_execute do
      @message_store.cleanup(older_than: older_than)
    end

    mock_execute.verify
  end
end
