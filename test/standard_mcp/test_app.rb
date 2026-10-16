require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"
Bundler.require(*Rails.groups)

require 'standard_api'
require 'standard_mcp'

# Test Application Config
Rails.env = 'test'

class TestApplication < Rails::Application
  config.root = File.join(File.dirname(__FILE__), 'test_app')
  config.secret_key_base = 'test key base'
  config.eager_load = true
  config.enable_reloading = false
  config.cache_store = :memory_store, { size: 8.megabytes }
  config.action_dispatch.show_exceptions = :none

  def config.database_configuration
    { "test" => {
      "adapter" => "postgresql",
      "database" => "standardmcp-test",
      "encoding" => "utf8"
    } }
  end
end

# Test Application initialization
TestApplication.initialize!

ActionView::Template.unregister_template_handler :jbuilder
ActionView::Template.register_template_handler :jbuilder, JbuilderHandler

# Test Application Models
require 'standard_mcp/test_app/models'

# Test Application Controllers
require 'standard_mcp/test_app/controllers'

# The Railtie's to_prepare ran before ApplicationController existed.
StandardMCP.define_server_controller!

# Test Application Routes
Rails.application.routes.draw do
  standard_mcp '/mcp'
  standard_mcp '/custom_mcp', to: 'mcp#handle', as: :custom_mcp

  standard_resources :accounts
  standard_resources :properties
  standard_resources :photos
  standard_resources :contacts
end

# Test Application Helpers
Object.const_set(:ApplicationHelper, Module.new)
