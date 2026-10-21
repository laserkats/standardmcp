require 'standard_mcp/test_helper'

# Definitions of the app's own: one that may be withheld (set by the ACL's
# schemas hook, as an app would), one a virtual attribute, and groups when the
# where selects several.
class AttrDocWithheldController < ApplicationController
  def self.model
    Property
  end

  def property_schemas(schemas)
    schemas.map { |schema| schema[:name] == 'rent' ? schema.merge(withheld: true) : schema }
  end
end

class AttrDocGroupedController < ApplicationController
  def self.model
    Property
  end

  def model_attribute_definitions(model, where)
    ids = where.is_a?(Hash) && where.dig('id', 'in')
    return super unless ids

    {
      'Group A' => [{ name: 'id', type: 'integer', primary_key: true }, { name: 'x', type: 'integer', read_only: false, null: true },
        { name: 'y', type: 'string', read_only: false, required: true }],
      'Group B' => [{ name: 'id', type: 'integer', primary_key: true }, { name: 'x', type: 'string', read_only: false, null: true }]
    }
  end
end

# Definitions saying what is writable, without the ACL's attributes.
class AttrDocCustomController < ApplicationController
  def self.model
    Property
  end

  def model_attribute_definitions(model, where)
    [
      { name: 'id', type: 'integer', primary_key: true, read_only: false },
      { name: 'ro', type: 'string', read_only: true },
      { name: 'auto', type: 'string', read_only: false, auto_populated: true },
      { name: 'stamp', type: 'datetime', read_only: false },
      { name: 'created_at', type: 'datetime', read_only: false },
      { name: 'plain', type: 'string', read_only: false, comment: 'A plain one.' },
      { name: 'must', type: 'string', read_only: false, required: true },
      { name: 'defaulted', type: 'string', read_only: false, required: true, default: 'x' },
      { name: 'unflagged', type: 'string' },
      { name: 'size', type: 'integer' }
    ]
  end
end

class SchemaAttributesDocumentTest < ActiveSupport::TestCase

  LINKS = { Account => 'accounts', Photo => 'gallery', Property => 'properties' }.freeze
  READS = %i[index show calculate].freeze
  WRITES = %i[create update].freeze

  def request_for(headers = {})
    env = Rack::MockRequest.env_for('/mcp', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    ActionDispatch::Request.new(env)
  end

  def doc(klass = PropertiesController, actions: READS + WRITES, where: nil, links: LINKS)
    controller = StandardMCP::Registry.controller_for(klass, request_for)
    StandardMCP::Schema::AttributesDocument.for(controller, name: 'properties', actions: actions, links: links, where: where)
  end

  def attribute(document, name)
    document['attributes'].find { |a| a['name'] == name } or flunk "no attribute #{name}"
  end

  # --- header and types

  test "the document names the resource and carries the table comment" do
    document = doc

    assert_equal 'properties', document['resource']
    assert_equal 'A real estate asset owned by an account.', document['description']
    refute document.key?('groups')
  end

  test "every attribute is listed with its type, in the order of the model" do
    assert_equal Property.attribute_names, doc['attributes'].map { |a| a['name'] }
    assert_equal %w[integer integer string integer text string boolean date datetime decimal string[] jsonb datetime datetime],
      doc['attributes'].map { |a| a['type'] }
  end

  test "comments, enums and nullability" do
    document = doc

    assert_equal 'Rentable area in square feet.', attribute(document, 'size')['description']
    assert_equal true, attribute(document, 'size')['nullable']
    assert_equal %w[office retail industrial], attribute(document, 'kind')['enum']
    assert_equal({ 'name' => 'id', 'type' => 'integer' }, attribute(document, 'id'))
    refute attribute(document, 'name').key?('enum')
  end

  test "no false, nil or empty value anywhere" do
    check = ->(value, path) do
      case value
      when Hash then value.each { |k, v| check.(v, "#{path}.#{k}") }
      when Array
        refute_empty value, "#{path} is empty"
        value.each_with_index { |v, i| check.(v, "#{path}[#{i}]") }
      else refute_includes [false, nil, ''], value, "#{path} is #{value.inspect}"
      end
    end

    [PropertiesController, AccountsController, AttrDocWithheldController, AttrDocCustomController].each do |klass|
      check.(doc(klass), klass.name)
    end
    check.(doc(AttrDocGroupedController, where: { 'id' => { 'in' => [1] } }), 'grouped')
  end

  test "hidden attributes are absent" do
    klass = Class.new(ApplicationController) do
      def self.model = Photo
      def photo_excludes(_record) = { internal_path: true }
    end
    controller = StandardMCP::Registry.controller_for(klass, request_for)
    document = StandardMCP::Schema::AttributesDocument.for(controller, name: 'photos', actions: READS)

    assert_equal %w[id property_id format caption created_at updated_at], document['attributes'].map { |a| a['name'] }
    refute_includes JSON.generate(document), 'internal_path'
  end

  # --- writable and required, per caller

  test "a reader has nothing writable or required" do
    document = doc(actions: READS)

    document['attributes'].each do |a|
      refute a.key?('writable'), a['name']
      refute a.key?('required'), a['name']
    end
    refute document.key?('notes') && document['notes'].include?('writable')
  end

  test "a writer's writable attributes are the ACL's attributes, minus ids, timestamps and database-filled columns" do
    document = doc

    assert_equal %w[account_id name kind size description available built_on rent].sort,
      document['attributes'].select { |a| a['writable'] }.map { |a| a['name'] }.sort
    %w[id created_at updated_at tags metadata listed_at].each { |name| refute attribute(document, name).key?('writable'), name }
  end

  test "an update-only caller can write what an update takes, and requires nothing" do
    document = doc(actions: %i[update])

    assert attribute(document, 'size')['writable']
    document['attributes'].each { |a| refute a.key?('required'), a['name'] }
  end

  test "required needs create, a required definition and no default" do
    assert_equal ['name'], doc['attributes'].select { |a| a['required'] }.map { |a| a['name'] }
    assert_equal ['name'], doc(ContactsController)['attributes'].select { |a| a['required'] }.map { |a| a['name'] }
    assert_empty doc(actions: %i[update])['attributes'].select { |a| a['required'] }
    # role is NOT NULL but has a default.
    refute attribute(doc(ContactsController), 'role').key?('required')
    assert attribute(doc(ContactsController), 'role')['writable']
  end

  test "the foreign key of a belongs_to that must be present is required, as it is for the write tools" do
    Contact.stubs(:validators_on).with(:account).returns([ActiveModel::Validations::PresenceValidator.new(attributes: [:account])])
    Contact.stubs(:validators_on).with(:account_id).returns([])
    Contact.stubs(:validators_on).with(Not(any_of(:account, :account_id))).returns([])

    assert_includes StandardMCP::Schema::Attributes.required(StandardMCP::Registry.controller_for(ContactsController, request_for), Contact), 'account_id'
    assert attribute(doc(ContactsController), 'account_id')['required']
  end

  test "writable and required follow the definitions: read_only, primary key, database-filled, timestamps" do
    document = doc(AttrDocCustomController)
    writable = document['attributes'].select { |a| a['writable'] }.map { |a| a['name'] }

    # stamp is writable: only the model's own timestamps (created_at) are not.
    assert_equal %w[defaulted must plain size stamp], writable.sort
    refute attribute(document, 'id').key?('writable'), 'a primary key'
    refute attribute(document, 'ro').key?('writable'), 'read_only'
    refute attribute(document, 'auto').key?('writable'), 'auto_populated'
    refute attribute(document, 'created_at').key?('writable'), 'a timestamp'
  end

  test "a definition without read_only is writable only if the ACL's attributes permit it" do
    document = doc(AttrDocCustomController)

    # size is in PropertyACL#attributes, unflagged is not.
    assert attribute(document, 'size')['writable']
    refute attribute(document, 'unflagged').key?('writable')
  end

  test "required needs the definition to say so, writable and no default" do
    document = doc(AttrDocCustomController)

    assert attribute(document, 'must')['required']
    refute attribute(document, 'defaulted').key?('required')
    refute attribute(document, 'plain').key?('required')
    refute attribute(document, 'ro').key?('required')
  end

  # --- withheld

  test "withheld comes from the definition, as the ACL's schemas hook sets it" do
    document = doc(AttrDocWithheldController)

    assert_equal true, attribute(document, 'rent')['withheld']
    assert_equal ['rent'], document['attributes'].select { |a| a['withheld'] }.map { |a| a['name'] }
    assert_includes document['notes'], 'withheld: the value may be left out of a record for privacy.'
  end

  test "no withheld attribute, no note about it" do
    refute_includes doc['notes'].to_s, 'withheld'
  end

  # --- associations

  test "a reader's associations are the includable ones, by name, kind and resource" do
    assert_equal [{ 'name' => 'account', 'kind' => 'belongs_to', 'resource' => 'accounts' },
      { 'name' => 'photos', 'kind' => 'has_many', 'resource' => 'gallery' }], doc(actions: READS)['associations']
  end

  test "a writer's nested associations are writable" do
    assert_equal [{ 'name' => 'account', 'kind' => 'belongs_to', 'resource' => 'accounts' },
      { 'name' => 'photos', 'kind' => 'has_many', 'resource' => 'gallery', 'writable' => 'nested' }], doc['associations']
    assert_includes doc['notes'], 'writable "nested"'
    refute_includes doc(actions: READS)['notes'].to_s, 'nested'
  end

  test "an association is named without the columns of the associated model" do
    json = JSON.generate(doc['associations'])

    %w[status notes caption format internal_path].each { |name| refute_includes json, name }
  end

  test "an association no exposed resource serves is a name and a kind" do
    assert_equal [{ 'name' => 'account', 'kind' => 'belongs_to' },
      { 'name' => 'photos', 'kind' => 'has_many', 'writable' => 'nested' }], doc(links: {})['associations']
  end

  test "a nested association is listed for a writer even when it can't be included" do
    klass = Class.new(ApplicationController) do
      def self.model = Property
      def property_includes = [:account]
    end

    assert_equal %w[account photos], doc(klass)['associations'].map { |a| a['name'] }
    assert_equal %w[account], doc(klass, actions: READS)['associations'].map { |a| a['name'] }
  end

  test "a destroy-only caller has no associations" do
    refute doc(actions: %i[destroy]).key?('associations')
  end

  # --- notes

  test "the notes explain only the flags that appear" do
    assert_equal 'writable: create_*/update_* can set it. required: create_* must send it. ' \
      'writable "nested": records of the association can be written through this one.', doc['notes']
    assert_equal 'writable: create_*/update_* can set it.', doc(actions: %i[update], links: {}).fetch('notes').sub(/ writable "nested".*/, '')
    refute doc(actions: READS).key?('notes')
  end

  # --- definitions that depend on the where

  test "without a where the definitions are those of no where" do
    document = doc(AttrDocGroupedController)

    assert_equal Property.attribute_names, document['attributes'].map { |a| a['name'] }
    refute document.key?('groups')
  end

  test "a where over several groups returns every attribute, labelled" do
    document = doc(AttrDocGroupedController, where: { 'id' => { 'in' => [1, 2] } })

    assert_equal ['Group A', 'Group B'], document['groups']
    assert_equal %w[id x y], document['attributes'].map { |a| a['name'] }
    assert_equal({ 'name' => 'id', 'type' => 'integer' }, attribute(document, 'id'))
    assert_equal({ 'name' => 'x', 'types' => { 'Group A' => 'integer', 'Group B' => 'string' }, 'nullable' => true, 'writable' => true },
      attribute(document, 'x'))
    assert_equal({ 'name' => 'y', 'type' => 'string', 'writable' => true, 'required' => true, 'only_in' => ['Group A'] },
      attribute(document, 'y'))
    assert_includes document['notes'], 'only_in: the attribute exists only in those groups.'
    assert_includes document['notes'], 'types: its type in each group.'
  end

  test "the hook is asked once, for the where passed" do
    where = { 'id' => { 'in' => [1] } }
    controller = StandardMCP::Registry.controller_for(PropertiesController, request_for)
    controller.expects(:model_attribute_definitions).once.with(Property, where).returns([{ name: 'size', type: 'integer' }])

    document = StandardMCP::Schema::AttributesDocument.for(controller, name: 'properties', actions: READS, where: where)

    assert_equal %w[size], document['attributes'].map { |a| a['name'] }
  end

end
