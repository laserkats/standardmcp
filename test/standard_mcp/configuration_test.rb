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

  test "the resource settings default to both resources, describe and standardmcp" do
    assert_equal %i[schema records], StandardMCP.config.resources
    assert_equal true, StandardMCP.config.describe_tools
    assert_equal 'standardmcp', StandardMCP.config.resource_scheme
  end

  test "max_limit defaults to 100 and takes a positive integer or nil" do
    assert_equal 100, StandardMCP.config.max_limit

    StandardMCP.config.max_limit = 50
    assert_equal 50, StandardMCP.config.max_limit
    StandardMCP.config.max_limit = nil
    assert_nil StandardMCP.config.max_limit

    [0, -1, 1.5, '10', :ten].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { StandardMCP.config.max_limit = value }
      assert_match(/max_limit must be a positive Integer or nil/, error.message)
    end
  end

  test "resources accepts symbols and strings, and an empty list" do
    StandardMCP.config.resources = ['records']
    assert_equal %i[records], StandardMCP.config.resources

    StandardMCP.config.resources = %i[schema schema]
    assert_equal %i[schema], StandardMCP.config.resources

    StandardMCP.config.resources = []
    assert_equal [], StandardMCP.config.resources

    StandardMCP.config.resources = nil
    assert_equal [], StandardMCP.config.resources
  end

  test "resources rejects what it doesn't serve" do
    error = assert_raises(ArgumentError) { StandardMCP.config.resources = %i[schema logs] }

    assert_includes error.message, 'got :logs'
    assert_equal %i[schema records], StandardMCP.config.resources
  end

  test "resource_scheme takes RFC 3986 scheme characters only" do
    StandardMCP.config.resource_scheme = 'my-app+v2.1'
    assert_equal 'my-app+v2.1', StandardMCP.config.resource_scheme

    ['', '1app', 'my app', 'app:', 'app://', 'ap_p', nil, :app].each do |value|
      assert_raises(ArgumentError, value.inspect) { StandardMCP.config.resource_scheme = value }
    end
    assert_equal 'my-app+v2.1', StandardMCP.config.resource_scheme
  end

end
