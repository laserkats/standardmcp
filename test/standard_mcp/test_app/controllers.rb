class ApplicationController < ActionController::Base
  include StandardAPI::Controller
  include StandardAPI::AccessControlList

  helper_method :serialize_attribute

  def serialize_attribute(json, record, attribute, type)
    json.set! attribute, record.send(attribute)
  end

  # Forgery protection is on (the test app enables it below), so in-process
  # writes only pass when verified_request? is satisfied.
  protect_from_forgery with: :exception

  # Key an app can set through StandardMCP.config.dispatch_env to mark a
  # dispatched request as trusted.
  VERIFIED_ENV = 'standardmcp.test.verified'.freeze

  before_action :count_visit

  # "Authorization: Bearer <account_id>" means acting as that account; a
  # session[:account_id] (read via the forwarded cookie) works too.
  def current_account_id
    token = request.authorization.to_s[/\ABearer (\d+)\z/, 1]
    token&.to_i || session[:account_id]
  end

  # Placeholder row mask. Return a filter hash (e.g. { id: 1 }) to restrict
  # rows of +table_name+; nil means unrestricted.
  def mask_for(table_name)
    nil
  end

  private

  # A session write, to show a dispatched call can't change the caller's.
  def count_visit
    session[:visits] = session.fetch(:visits, 0) + 1
  end

  # Bearer callers carry no session cookie, so they skip CSRF, as do requests
  # a dispatch_env hook marked verified.
  def verified_request?
    super || current_account_id.present? || request.env[VERIFIED_ENV] == true
  end
end

class AccountsController < ApplicationController
  allow_mcp only: [:index, :show, :calculate]

  def mask_for(table_name)
    { id: current_account_id } if table_name.to_s == 'accounts' && current_account_id
  end
end

class PropertiesController < ApplicationController
  # Writes are only visible to callers sending X-MCP-Writes; reads always are.
  allow_mcp except: [:destroy], if: :mcp_writes?
  allow_mcp only: [:index, :show]

  def mask_for(table_name)
    { account_id: current_account_id } if table_name.to_s == 'properties' && current_account_id
  end

  private

  def mcp_writes?
    request.headers['X-MCP-Writes'] == 'true'
  end
end

# No MCP intent: never opts in with allow_mcp.
class PhotosController < ApplicationController
end
