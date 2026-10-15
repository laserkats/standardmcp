module StandardMCP
  class Error < StandardError; end

  # The action isn't allowed for this request (no rule covers it, or its
  # conditions failed). Raised before anything is dispatched.
  class ActionNotAllowed < Error; end

  # The dispatched action responded in a way that isn't a tool-level error
  # (e.g. a 5xx), so it should surface as a server error.
  class DispatchError < Error; end
end
