class ApplicationController < ActionController::Base
  include StandardAPI::Controller
  include StandardAPI::AccessControlList

  helper_method :serialize_attribute

  def serialize_attribute(json, record, attribute, type)
    json.set! attribute, record.send(attribute)
  end

  # Placeholder row mask. Return a filter hash (e.g. { id: 1 }) to restrict
  # rows of +table_name+; nil means unrestricted.
  def mask_for(table_name)
    nil
  end
end

class AccountsController < ApplicationController
  allow_mcp only: [:index, :show, :calculate]
end

class PropertiesController < ApplicationController
  # Writes are only visible to callers sending X-MCP-Writes; reads always are.
  allow_mcp except: [:destroy], if: :mcp_writes?
  allow_mcp only: [:index, :show]

  private

  def mcp_writes?
    request.headers['X-MCP-Writes'] == 'true'
  end
end

# No MCP intent: never opts in with allow_mcp.
class PhotosController < ApplicationController
end
