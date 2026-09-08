-- Let Rime decode mixed sentences while keeping the original Chinese translator
-- and its learned vocabulary independent of the supplemental English lexicon.
local M = {}

function M.init(env)
  env.translator = Component.Translator(env.engine, "mixed", "script_translator")
  env.memory = Memory(env.engine, env.engine.schema, "mixed")
end

function M.fini(env)
  env.memory:disconnect()
end

local function admitted_ascii_runs(text, input, env)
  if env.cache_input ~= input then
    env.cache_input, env.admitted = input, {}
  end
  for run in text:gmatch("[A-Za-z]+") do
    local admitted = env.admitted[run]
    if admitted == nil then
      admitted = false
      env.memory:dict_lookup(run, false, 0)
      for entry in env.memory:iter_dict() do
        if entry.text == run then admitted = true; break end
      end
      env.admitted[run] = admitted
    end
    if not admitted then return false end
  end
  return true
end

function M.func(input, segment, env)
  local translation = env.translator:query(input, segment)
  if not translation then return end
  for candidate in translation:iter() do
    -- Script translation visits longer covered spans first. The remaining
    -- partial words cannot produce a complete mixed sentence for this input.
    if candidate._end < segment._end then break end
    -- Only complete, genuinely mixed results belong in this supplemental stream.
    -- UTF-8 Chinese characters contain non-ASCII bytes; the dictionary contains
    -- only Chinese entries and literal alphabetic English entries.
    if candidate.text:find("[A-Za-z]")
        and candidate.text:find("[\128-\255]")
        and admitted_ascii_runs(candidate.text, input, env) then
      -- Native Chinese wins when it covers the same input. A complete mixed
      -- sentence can still lead a shorter Chinese translation via Rime's span order.
      candidate.quality = -0.5
      yield(candidate)
    end
  end
end

return M
