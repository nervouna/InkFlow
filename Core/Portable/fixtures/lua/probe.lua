return function(input)
  for candidate in input:iter() do
    candidate.comment = "Lua ✓"
    if candidate.text == "你" then
      candidate.preedit = "你"
    end
    yield(candidate)
  end
end
