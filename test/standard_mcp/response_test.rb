require 'standard_mcp/test_helper'

class ResponseTest < ActiveSupport::TestCase
  # Stand-in for StandardMCP::Dispatcher::Result.
  FakeResult = Struct.new(:status, :headers, :body) do
    def json
      JSON.parse(body) if body && !body.empty?
    rescue JSON::ParserError
      nil
    end
  end

  def result(status, body = '', headers = {})
    body = JSON.generate(body) unless body.is_a?(String)
    FakeResult.new(status, headers, body)
  end

  def from(res, action, **opts)
    StandardMCP::Response.from(res, action: action, **opts)
  end

  def assert_error(response, message, errors: nil)
    assert response.error?
    assert_equal message, response.structured_content[:error]
    if errors
      assert_equal errors, response.structured_content[:errors]
    else
      refute response.structured_content.key?(:errors)
    end
    assert_equal JSON.generate(response.structured_content), response.content.first[:text]
  end

  test "index wraps the array in records" do
    response = from(result(200, [{ 'id' => 1 }, { 'id' => 2 }]), :index)

    refute response.error?
    assert_equal({ records: [{ 'id' => 1 }, { 'id' => 2 }] }, response.structured_content)
  end

  test "index with no rows returns an empty records array" do
    assert_equal({ records: [] }, from(result(200, []), :index).structured_content)
  end

  test "index merges extra into the structured content" do
    response = from(result(200, [{ 'id' => 1 }]), :index, extra: { total: 5 })

    assert_equal({ records: [{ 'id' => 1 }], total: 5 }, response.structured_content)
    assert_equal JSON.generate(response.structured_content), response.content.first[:text]
  end

  test "show, create and update wrap the record" do
    { show: 200, create: 201, update: 200 }.each do |action, status|
      response = from(result(status, { 'id' => 1, 'name' => 'a' }), action)

      refute response.error?, action
      assert_equal({ record: { 'id' => 1, 'name' => 'a' } }, response.structured_content, action)
    end
  end

  test "calculate wraps an array" do
    assert_equal({ result: [3] }, from(result(200, [3]), :calculate).structured_content)
  end

  test "calculate wraps a grouped hash" do
    response = from(result(200, { 'a' => 1, 'b' => 2 }), :calculate)

    assert_equal({ result: { 'a' => 1, 'b' => 2 } }, response.structured_content)
  end

  test "destroy reports affected rows" do
    response = from(result(204, '', 'Affected-Rows' => '2'), :destroy)

    refute response.error?
    assert_equal({ success: true, affected_rows: 2 }, response.structured_content)
  end

  test "destroy accepts an integer or lowercased header" do
    assert_equal 3, from(result(204, '', 'affected-rows' => 3), :destroy).structured_content[:affected_rows]
  end

  test "destroy without the header omits affected_rows" do
    assert_equal({ success: true }, from(result(204), :destroy).structured_content)
    assert_equal({ success: true }, from(result(204, '', 'Affected-Rows' => 'x'), :destroy).structured_content)
  end

  test "content is a single compact JSON text item matching structured content" do
    response = from(result(200, [{ 'id' => 1 }]), :index)

    assert_equal 1, response.content.size
    assert_equal 'text', response.content.first[:type]
    assert_equal '{"records":[{"id":1}]}', response.content.first[:text]
  end

  test "to_h has the protocol shape" do
    h = from(result(200, { 'id' => 1 }), :show).to_h

    assert_equal [:content, :isError, :structuredContent], h.keys.sort
    assert_equal false, h[:isError]
    assert_equal({ record: { 'id' => 1 } }, h[:structuredContent])
    assert_equal [{ type: 'text', text: '{"record":{"id":1}}' }], h[:content]
  end

  test "error to_h sets isError" do
    h = StandardMCP::Response.error('nope').to_h

    assert_equal true, h[:isError]
    assert_equal({ error: 'nope' }, h[:structuredContent])
    assert_equal [{ type: 'text', text: '{"error":"nope"}' }], h[:content]
  end

  test "400 with validation errors flattens them and keeps the hash" do
    errors = { 'name' => ["can't be blank"], 'size' => ['must be greater than 0', 'is not a number'] }
    response = from(result(400, { 'id' => nil, 'errors' => errors }), :create)

    assert_error response,
      "name can't be blank, size must be greater than 0, size is not a number",
      errors: errors
  end

  test "base errors have no attribute prefix" do
    response = from(result(400, { 'errors' => { 'base' => ['is invalid'] } }), :update)

    assert_error response, 'is invalid', errors: { 'base' => ['is invalid'] }
  end

  test "400 with an errors array uses it as the message" do
    response = from(result(400, { 'errors' => ['Relationship violates unique constraints'] }), :update)

    assert_error response, 'Relationship violates unique constraints', errors: ['Relationship violates unique constraints']
  end

  test "400 plain text from ParameterMissing is the message" do
    response = from(result(400, 'param is missing or the value is empty: limit'), :index)

    assert_error response, 'param is missing or the value is empty: limit'
  end

  test "400 plain text from UnpermittedParameters is the message" do
    response = from(result(400, 'found unpermitted parameter: :limit, 5000'), :index)

    assert_error response, 'found unpermitted parameter: :limit, 5000'
  end

  test "400 JSON without errors falls back to the body error or a generic message" do
    assert_error from(result(400, { 'error' => 'bad' }), :show), 'bad'
    assert_error from(result(400, { 'id' => 1 }), :show), 'Request failed with status 400'
    assert_error from(result(400), :show), 'Request failed with status 400'
  end

  test "422 is handled like 400" do
    errors = { 'name' => ['is too short'] }

    assert_error from(result(422, { 'errors' => errors }), :create), 'name is too short', errors: errors
    assert_error from(result(422, 'unprocessable'), :create), 'unprocessable'
  end

  test "401 is Unauthorized" do
    assert_error from(result(401, 'ignored'), :show), 'Unauthorized'
  end

  test "403 is Forbidden with optional detail" do
    assert_error from(result(403), :show), 'Forbidden'
    assert_error from(result(403, { 'error' => 'not yours' }), :show), 'Forbidden: not yours'
  end

  test "404 is Not found, preferring the body error" do
    assert_error from(result(404), :show), 'Not found'
    assert_error from(result(404, '<html>nope</html>'), :show), 'Not found'
    assert_error from(result(404, { 'error' => "Couldn't find Account" }), :show), "Couldn't find Account"
  end

  test "other 4xx get a generic message with the status" do
    assert_error from(result(409, 'conflict body'), :update), 'Request failed with status 409'
    assert_error from(result(429), :index), 'Request failed with status 429'
  end

  test "5xx raises DispatchError with the status and a truncated body" do
    error = assert_raises(StandardMCP::DispatchError) { from(result(500, 'x' * 1000), :show) }

    assert_includes error.message, '500'
    assert_operator error.message.length, :<, 300
    assert_includes error.message, '...'
  end

  test "unexpected 1xx and 3xx raise DispatchError" do
    [102, 302].each do |status|
      error = assert_raises(StandardMCP::DispatchError) { from(result(status), :show) }
      assert_includes error.message, status.to_s
    end
  end

  test "a success body of the wrong shape raises DispatchError" do
    assert_raises(StandardMCP::DispatchError) { from(result(200, { 'id' => 1 }), :index) }
    assert_raises(StandardMCP::DispatchError) { from(result(200, [1]), :show) }
    assert_raises(StandardMCP::DispatchError) { from(result(200), :show) }
  end

  test "unknown action raises ArgumentError" do
    error = assert_raises(ArgumentError) { from(result(200, []), :explode) }
    assert_includes error.message, 'explode'
  end

  test "string actions are accepted" do
    assert_equal({ records: [] }, from(result(200, []), 'index').structured_content)
  end

  test "error builds a tool error with optional errors" do
    assert_error StandardMCP::Response.error('boom'), 'boom'
    assert_error StandardMCP::Response.error('boom', errors: { 'a' => ['b'] }), 'boom', errors: { 'a' => ['b'] }
  end

  test "not_allowed names the action" do
    assert_error StandardMCP::Response.not_allowed(:destroy), 'Action destroy is not allowed'
  end
end
