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
    local function collect(completion)
      env.memory:dict_lookup(input, completion, 0)
      for entry in env.memory:iter_dict() do
        local previous = seen[entry.text]
        if not previous then
          previous = { text = entry.text, weight = entry.weight, exact = not completion }
          seen[entry.text] = previous
          entries[#entries + 1] = previous
        else
          if entry.weight > previous.weight then previous.weight = entry.weight end
          if not completion then previous.exact = true end
        end
      end
    end
    -- Exact code lookup is separate from completion lookup so aliases such as
    -- cpp -> C++ rank with exact words. One- and two-letter inputs stay exact-only.
    collect(false)
    if #input >= 3 then collect(true) end
    table.sort(entries, function(a, b)
      if a.exact ~= b.exact then return a.exact end
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
