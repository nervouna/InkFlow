-- Let Rime decode mixed sentences while keeping the original Chinese translator
-- and its learned vocabulary independent of the supplemental English lexicon.
local M = {}

function M.init(env)
  env.translator = Component.Translator(env.engine, "mixed", "script_translator")
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
        and candidate.text:find("[\128-\255]") then
      -- Prefer the decoder's mixed sentence to an auto-assembled Pinyin sentence
      -- (quality 0), while normal Chinese dictionary phrases keep their priority.
      candidate.quality = 0.5
      yield(candidate)
    end
  end
end

return M
