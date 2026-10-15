# = Models

class Account < ActiveRecord::Base
  has_many :properties
end

class Property < ActiveRecord::Base
  belongs_to :account
  has_many :photos

  validates :name, presence: true
end

class Photo < ActiveRecord::Base
  belongs_to :property
end

# = Create/recreate database and schema
db_config = ActiveRecord::Base.connection_db_config
ActiveRecord::Tasks::DatabaseTasks.drop(db_config)
ActiveRecord::Tasks::DatabaseTasks.create(db_config)

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table "accounts", force: :cascade, comment: "A customer organization that owns properties." do |t|
    t.string   "name",   comment: "Display name of the organization."
    t.string   "status", comment: "Lifecycle status, e.g. active or suspended."
    t.text     "notes"
    t.timestamps
  end

  create_table "properties", force: :cascade, comment: "A real estate asset owned by an account." do |t|
    t.integer "account_id", comment: "The account that owns this property."
    t.string  "name",       comment: "Marketing name of the property."
    t.integer "size",       comment: "Rentable area in square feet."
    t.text    "description", comment: "Free-form description of the property."
    t.timestamps
  end

  create_table "photos", force: :cascade, comment: "An image attached to a property." do |t|
    t.integer "property_id", comment: "The property this photo depicts."
    t.string  "format",        comment: "Image file format."
    t.string  "caption"
    t.string  "internal_path", comment: "Storage path. Never exposed through the API."
    t.timestamps
  end

  add_foreign_key "properties", "accounts"
  add_foreign_key "photos", "properties"
end
