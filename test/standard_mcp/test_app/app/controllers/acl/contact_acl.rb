module ContactACL

  def attributes
    [ :account_id, :name, :email, :role, :age ]
  end

  def orders
    [ :id, :name ]
  end

  def includes
    [ :account ]
  end

  def wheres
    [ :id, :account_id, :name, :email, :role, :age, :created_at, :updated_at, :account ]
  end

end
