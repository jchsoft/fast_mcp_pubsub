# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "logger"
require "stringio"
require "json"

# Mock ActiveSupport for testing
class String
  def inquiry
    StringInquirer.new(self)
  end
end

class StringInquirer < String
  def test?
    self == "test"
  end

  def production?
    self == "production"
  end

  def development?
    self == "development"
  end
end

# Mock Rails environment for testing
module Rails
  class << self
    attr_accessor :logger
  end

  def self.env
    @env ||= "test".inquiry
  end

  def self.const_defined?(name)
    return true if name == "Server"

    super
  end

  # Initialize logger for tests
  self.logger = Logger.new(StringIO.new)

  class Railtie
    def self.initializer(name, options = {}, &)
      # Mock initializer registration
    end
  end
end

Rails.logger = Logger.new(StringIO.new)

# Mock ActiveRecord for testing
module ActiveRecord
  class Base
    class << self
      def connection_pool
        @connection_pool ||= MockConnectionPool.new
      end

      def connection
        @connection ||= MockConnection.new
      end

      def connection_db_config
        MockConnectionDbConfig.new
      end
    end
  end

  class MockConnectionDbConfig
    def configuration_hash
      {
        host: "localhost",
        port: 5432,
        database: "test_db",
        username: "test_user",
        password: "test_pass"
      }
    end
  end

  class MockConnectionPool
    def checkout
      MockConnection.new
    end

    def checkin(conn)
      # no-op for testing
    end
  end

  class MockConnection
    def execute(sql)
      # Mock NOTIFY execution and other SQL execution
    end

    def quote(str)
      "'#{str}'"
    end

    def raw_connection
      MockRawConnection.new
    end

    def table_exists?(_table_name)
      false # Simulate table doesn't exist initially
    end

    def select_value(sql)
      # Mock for fetch_and_delete
      return unless sql.include?("DELETE FROM")

      '{"test":"payload"}'
    end
  end

  class MockRawConnection
    def async_exec(sql)
      # Mock LISTEN/UNLISTEN
    end

    def wait_for_notify
      # Mock notification waiting - will not actually wait in tests
    end
  end
end

# Mock FastMcp for testing
module FastMcp
  module Transports
    class RackTransport
      attr_accessor :running

      attr_reader :sse_clients, :endpoint_queries, :sent_messages, :handled_requests

      def initialize
        @running = false
        @sent_messages = []
        @sse_clients = {}
        @endpoint_queries = []
        @handled_requests = []
      end

      def send_message(message)
        @sent_messages << message
      end

      def send_local_message(message)
        @sent_messages << message
      end

      def running?
        @running
      end

      # Mirrors FastMcp's own registry so the targeted send has somewhere to write.
      def register_sse_client(client_id, stream, mutex = nil)
        @sse_clients[client_id] = { stream: stream, mutex: mutex || Mutex.new }
      end

      def unregister_sse_client(client_id)
        @sse_clients.delete(client_id)
      end

      def clear_messages
        @sent_messages.clear
      end

      private

      # The two private methods the patch wraps. Both record what they were
      # handed, which is what the tests assert on.
      def handle_message_request_with_server(request, server)
        @handled_requests << request
        [request, server, FastMcpPubsub::CurrentClient.id]
      end

      def setup_sse_connection(_client_id, _io, env)
        @endpoint_queries << env["QUERY_STRING"]
      end

      # FastMcp's own JSON-RPC error response, which the patch answers with.
      def json_rpc_error_response(http_status, code, message, id = nil)
        [http_status, { "Content-Type" => "application/json" }, [JSON.generate({ jsonrpc: "2.0", error: { code: code, message: message }, id: id })]]
      end
    end
  end
end

require "fast_mcp_pubsub"
require "minitest/autorun"
require "minitest/mock"

# Records what was written to one client's SSE stream.
class FakeSseStream
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write(data)
    @writes << data
  end

  def flush; end

  def closed?
    false
  end
end

# Collects the NOTIFY payloads Service.broadcast would send.
module BroadcastCapture
  private

  def capture_payloads(&)
    payloads = []
    FastMcpPubsub::Service.stub(:send_payload, ->(payload) { payloads << payload }, &)
    payloads
  end
end

# Returns what FastMcpPubsub.logger wrote while the block ran.
module LogCapture
  private

  def capture_log
    previous = Rails.logger
    log = StringIO.new
    Rails.logger = Logger.new(log)
    yield
    log.string
  ensure
    Rails.logger = previous
  end
end
