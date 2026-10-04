return function(input)
  for candidate in input:iter() do
    candidate.comment = "Lua ✓"
    yield(candidate)
  end
end
