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

end
