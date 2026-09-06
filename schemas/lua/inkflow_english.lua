-- Use Rime's compiled English dictionary, but rank across completion lengths.
local M = {}

function M.init(env)
  env.memory = Memory(env.engine, env.engine.schema, "english")
end

function M.fini(env)
  env.memory:disconnect()
end

function M.func(input, segment, env)
  if not input:match("^[A-Za-z]+$") then return end
  if env.input ~= input then
    local entries, seen = {}, {}
    -- Short prefixes have tens of thousands of matches. Keep exact words there;
    -- from three letters, inspect every match so a frequent long word is not lost.
    env.memory:dict_lookup(input, #input >= 3, 0)
    for entry in env.memory:iter_dict() do
      local previous = seen[entry.text]
      if not previous then
        previous = { text = entry.text, weight = entry.weight }
        seen[entry.text] = previous
        entries[#entries + 1] = previous
      elseif entry.weight > previous.weight then
        previous.weight = entry.weight
      end
    end
    table.sort(entries, function(a, b)
      if a.weight ~= b.weight then return a.weight > b.weight end
      if (a.text == input) ~= (b.text == input) then return a.text == input end
      return a.text < b.text
    end)
    -- Retain only one lookup per translator/session, including while paging.
    env.input, env.entries = input, entries
  end
  for _, entry in ipairs(env.entries) do
    local candidate = Candidate("english", segment.start, segment._end, entry.text, "")
    -- Native Chinese wins equal input coverage, including an unfinished final
    -- syllable. This entire stream still keeps its source-frequency order.
    candidate.quality = -1
    yield(candidate)
  end
end

return M
