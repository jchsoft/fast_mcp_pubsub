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
    return true if name == 'Server'
    super
  end
  
  class Railtie
    def self.initializer(name, options = {}, &block)
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
      # Mock NOTIFY execution
    end
    
    def quote(str)
      "'#{str}'"
    end
    
    def raw_connection
      MockRawConnection.new
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
      def send_message(message)
        # Mock implementation
      end
      
      def running?
        true
      end
    end
  end
end

require "fast_mcp_pubsub"
require "minitest/autorun"
