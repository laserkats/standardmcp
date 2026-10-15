module AccountACL

  def attributes
    [ :name, :status, :notes ]
  end

  def orders
    [ :id, :name, :created_at ]
  end

  def includes
    [ :properties ]
  end

end
