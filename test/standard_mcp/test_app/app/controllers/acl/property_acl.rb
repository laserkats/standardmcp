module PropertyACL

  def attributes
    [ :account_id, :name, :size, :description ]
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
