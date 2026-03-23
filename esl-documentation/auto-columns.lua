function Table(tbl)
  for i, colspec in ipairs(tbl.colspecs) do
    colspec[2] = nil
  end
  return tbl
end
