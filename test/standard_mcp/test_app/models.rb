# = Models

class Account < ActiveRecord::Base
  has_many :properties
end

class Property < ActiveRecord::Base
  belongs_to :account
  has_many :photos

  # An AR enum (string-valued) so the schema's enum path is exercised.
  enum :kind, { office: 'office', retail: 'retail', industrial: 'industrial' }

  validates :name, presence: true
end

class Photo < ActiveRecord::Base
  belongs_to :property

  # The inclusion-validator path to enum values.
  validates :format, inclusion: { in: %w[jpg png tiff] }, allow_nil: true
end

# Covers the write schemas: a NOT NULL column, a column with a default, and a
# validator each for length, format, numericality and inclusion.
class Contact < ActiveRecord::Base
  belongs_to :account

  validates :name, length: { maximum: 50 }
  validates :email, format: { with: /\A[^@\s]+@[^@\s]+\z/ }, allow_nil: true
  validates :role, inclusion: { in: %w[member admin] }
  validates :age, numericality: { greater_than_or_equal_to: 0, less_than: 150 }, allow_nil: true
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
    t.string  "kind",        comment: "Asset class of the property."
    t.boolean "available",   default: true, comment: "Whether the property can be leased now."
    t.date    "built_on",    comment: "Date construction finished."
    t.datetime "listed_at",  comment: "When the property was listed for lease."
    t.decimal "rent",        precision: 10, scale: 2, comment: "Asking rent per square foot per year."
    t.string  "tags",        array: true, comment: "Free-form labels."
    t.jsonb   "metadata",    comment: "Unstructured attributes from the source system."
    t.timestamps
  end

  create_table "photos", force: :cascade, comment: "An image attached to a property." do |t|
    t.integer "property_id", comment: "The property this photo depicts."
    t.string  "format",        comment: "Image file format."
    t.string  "caption"
    t.string  "internal_path", comment: "Storage path. Never exposed through the API."
    t.timestamps
  end

  create_table "contacts", force: :cascade, comment: "A person to reach at an account." do |t|
    t.integer "account_id", comment: "The account this person works for."
    t.string  "name",  null: false, comment: "Full name."
    t.string  "email", comment: "Email address."
    t.string  "role",  null: false, default: "member", comment: "Access level."
    t.integer "age",   comment: "Age in years."
    t.timestamps
  end

  add_foreign_key "properties", "accounts"
  add_foreign_key "photos", "properties"
end
