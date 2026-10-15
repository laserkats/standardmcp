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

  # Evaluated per-record. internal_path never leaves the server.
  def excludes(record)
    { internal_path: true }
  end

end
