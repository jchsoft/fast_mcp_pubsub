# frozen_string_literal: true

module FastMcpPubsub
  class MessageStore
    TABLE_NAME = "fast_mcp_pubsub_messages"

    class << self
      def store(payload)
        ensure_table_exists
        id = SecureRandom.uuid
        ActiveRecord::Base.connection.execute(
          "INSERT INTO #{TABLE_NAME} (id, payload, created_at) VALUES (#{quote(id)}, #{quote(payload)}, NOW())"
        )
        id
      end

      def fetch_and_delete(id)
        ActiveRecord::Base.connection.select_value(
          "DELETE FROM #{TABLE_NAME} WHERE id = #{quote(id)} RETURNING payload"
        )
      end

      def cleanup(older_than: Time.now - 300)
        ActiveRecord::Base.connection.execute(
          "DELETE FROM #{TABLE_NAME} WHERE created_at < #{quote(older_than.iso8601)}"
        )
      end

      def ensure_table_exists
        return if @table_exists

        unless ActiveRecord::Base.connection.table_exists?(TABLE_NAME)
          ActiveRecord::Base.connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
              id UUID PRIMARY KEY,
              payload TEXT NOT NULL,
              created_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
          SQL
        end
        @table_exists = true
      end

      private

      def quote(value)
        ActiveRecord::Base.connection.quote(value)
      end
    end
  end
end
