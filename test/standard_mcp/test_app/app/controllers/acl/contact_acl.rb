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

end
