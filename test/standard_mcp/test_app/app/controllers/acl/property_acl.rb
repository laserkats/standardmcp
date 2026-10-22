module PropertyACL

  def attributes
    [ :account_id, :name, :kind, :size, :description, :available, :built_on, :rent ]
  end

  def orders
    [ :id, :name, :size, :created_at ]
  end

  def includes
    [ :account, :photos ]
  end

  def wheres
    [
      :id, :account_id, :name, :kind, :size, :description, :available, :built_on,
      :listed_at, :rent, :tags, :metadata, :created_at, :updated_at,
      :account, :photos
    ]
  end

  def nested
    [ :photos ]
  end

  # A list scoped to an account (the where names account_id) also has the name
  # of that account, which only makes sense there. Reads params[:where] like
  # an app's schemas hook does. No `wheres` entry: a controller that wants it
  # filterable permits it (see ScopedPropertiesController).
  def schemas(schemas)
    where = params[:where]
    scoped = Array.wrap(where).any? { |part| part.respond_to?(:key?) && part.key?(:account_id) }
    return schemas unless scoped

    schemas + [{
      name: 'account_name', type: 'string', enum: nil, default: nil, primary_key: false, null: true, array: false,
      comment: 'Name of the account the list is for.', auto_populated: false, read_only: true, required: false,
      validations: []
    }]
  end

end
