require 'standard_mcp/test_helper'

class ConfigurationTest < ActiveSupport::TestCase

  test "input_schema_depth defaults to shallow" do
    assert_equal 'shallow', StandardMCP.config.input_schema_depth
    refute StandardMCP.config.deep_input_schema?
  end

  test "input_schema_depth accepts strings and symbols, stored as strings" do
    StandardMCP.config.input_schema_depth = :deep
    assert_equal 'deep', StandardMCP.config.input_schema_depth
    assert StandardMCP.config.deep_input_schema?

    StandardMCP.config.input_schema_depth = 'shallow'
    assert_equal 'shallow', StandardMCP.config.input_schema_depth
  end

  test "input_schema_depth rejects anything else" do
    [:medium, 'Deep', '', nil, 1, true].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { StandardMCP.config.input_schema_depth = value }
      assert_match(/input_schema_depth must be one of shallow, deep, got #{Regexp.escape(value.inspect)}/, error.message)
    end

    assert_equal 'shallow', StandardMCP.config.input_schema_depth
  end

  test "a rejected value leaves the setting alone" do
    StandardMCP.config.input_schema_depth = 'deep'
    assert_raises(ArgumentError) { StandardMCP.config.input_schema_depth = 'nope' }

    assert_equal 'deep', StandardMCP.config.input_schema_depth
  end

  test "configure sets input_schema_depth and output_schema" do
    StandardMCP.configure do |config|
      config.input_schema_depth = :deep
      config.output_schema = true
    end

    assert_equal 'deep', StandardMCP.config.input_schema_depth
    assert_equal true, StandardMCP.config.output_schema
  end

  test "output_schema defaults to false" do
    assert_equal false, StandardMCP.config.output_schema
  end

end
