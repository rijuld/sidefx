# frozen_string_literal: true

module Sidefx
  # Just enough SQL understanding to say "INSERT into orders" or
  # "SELECT from line_items". No parser, no dependencies.
  module SQL
    PART = /["`\[]?\w+["`\]]?/
    IDENT = /(#{PART}(?:\.#{PART})*)/

    PATTERNS = [
      [:insert, /\A\s*(?:INSERT|REPLACE)\s+(?:OR\s+\w+\s+)?INTO\s+#{IDENT}/i],
      [:update, /\A\s*UPDATE\s+(?:OR\s+\w+\s+)?#{IDENT}/i],
      [:delete, /\A\s*DELETE\s+FROM\s+#{IDENT}/i],
      [:select, /\A\s*(?:WITH\b.*?\)\s*)?SELECT\b.*?\bFROM\s+#{IDENT}/im]
    ].freeze

    NOISE = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|PRAGMA|SET|SHOW|EXPLAIN)\b/i

    # Returns [operation, table] or nil for statements that aren't reads or writes.
    def self.classify(sql)
      return nil if sql.nil? || sql.match?(NOISE)

      PATTERNS.each do |op, re|
        m = sql.match(re)
        return [op, m[1].split(".").last.delete("\"`[]")] if m
      end
      nil
    end

    # Replace literals so repeated queries with different values look the same.
    def self.shape(sql)
      sql.gsub(/'(?:[^']|'')*'/, "?")
         .gsub(/\b\d+(\.\d+)?\b/, "?")
         .gsub(/\$\d+/, "?")
         .gsub(/\(\s*\?(?:\s*,\s*\?)*\s*\)/, "(?)")
         .gsub(/\s+/, " ")
         .strip
    end
  end
end
