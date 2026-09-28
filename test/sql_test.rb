# frozen_string_literal: true

require "test_helper"

class SQLTest < Minitest::Test
  def test_classify
    {
      'INSERT INTO "orders" ("total") VALUES (?)' => [:insert, "orders"],
      "INSERT OR IGNORE INTO users (a) VALUES (1)" => [:insert, "users"],
      'UPDATE "users" SET "orders_count" = COALESCE("orders_count", 0) + ?' => [:update, "users"],
      "DELETE FROM `public`.`sessions` WHERE id = 1" => [:delete, "sessions"],
      'SELECT "orders".* FROM "orders" WHERE "orders"."user_id" = ?' => [:select, "orders"],
      "WITH recent AS (SELECT 1) SELECT * FROM line_items" => [:select, "line_items"],
      "BEGIN" => nil,
      "SAVEPOINT active_record_1" => nil,
      "PRAGMA foreign_keys" => nil
    }.each do |sql, want|
      got = Sidefx::SQL.classify(sql)
      want.nil? ? assert_nil(got, sql) : assert_equal(want, got, sql)
    end
  end

  def test_shape_normalizes_literals
    a = Sidefx::SQL.shape("SELECT * FROM users WHERE id = 1 AND name = 'x' AND id IN (1, 2, 3)")
    b = Sidefx::SQL.shape("SELECT * FROM users WHERE id = 22 AND name = 'it''s' AND id IN (4)")
    assert_equal a, b
    assert_equal "SELECT * FROM users WHERE id = ? AND name = ? AND id IN (?)", a
  end
end
