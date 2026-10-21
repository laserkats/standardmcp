module PhotoACL

  def attributes
    [ :property_id, :format, :caption ]
  end

  def orders
    [ :id ]
  end

  def includes
    [ :property ]
  end

  # internal_path is left out: it can't be filtered on any more than it can be read.
  def wheres
    [ :id, :property_id, :format, :caption, :created_at, :updated_at, :property ]
  end

  # Evaluated per-record. internal_path never leaves the server.
  def excludes(record)
    { internal_path: true }
  end

end
