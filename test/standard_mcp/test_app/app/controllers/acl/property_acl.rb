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

  def nested
    [ :photos ]
  end

end
