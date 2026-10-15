require File.expand_path('../test_app', __FILE__)

require "minitest/autorun"
require 'factory_bot'
require 'faker'
require 'byebug'
require 'mocha/minitest'
require 'minitest/reporters'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

ActiveSupport.test_order = :random

FactoryBot.definition_file_paths = [File.expand_path('../test_app/test', __FILE__)]
FactoryBot.find_definitions

class ActiveSupport::TestCase
  include ActiveRecord::TestFixtures
  include FactoryBot::Syntax::Methods

  self.use_transactional_tests = true

  def setup
    @routes ||= TestApplication.routes
    StandardMCP.reset_config!
  end

  def connection
    ActiveRecord::Base.connection
  end
end
