-- Let Rime decode mixed sentences while keeping the original Chinese translator
-- and its learned vocabulary independent of the supplemental English lexicon.
local M = {}

function M.init(env)
  env.translator = Component.Translator(env.engine, "mixed", "script_translator")
  env.memory = Memory(env.engine, env.engine.schema, "mixed")
  env.personal = Memory(env.engine, env.engine.schema, "english")
  env.short_conflicts = {}
  local config, path = env.engine.schema.config, "inkflow_short_conflict/inputs"
  env.max_personal_input_length = config:get_int("mixed_personal/max_input_length") or 64
  for index = 0, config:get_list_size(path) - 1 do
    local input = config:get_string(path .. "/@" .. index)
    if input then env.short_conflicts[input] = true end
  end
end

function M.fini(env)
  env.memory:disconnect()
  env.personal:disconnect()
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

local function personal_matches(input, env)
  if env.personal_input == input then return env.personal_matches end
  local matches, lower, seen = {}, input:lower(), {}
  if #input > env.max_personal_input_length then
    env.personal_input, env.personal_matches = input, matches
    return matches
  end
  if env.personal.user_dict and env.personal.user_dict.loaded then
    -- Ask for at most one predictive row only to decide whether a longer prefix
    -- can exist. Exact display variants come from the non-predictive Memory path.
    for first = 1, #lower do
      for last = first, #lower do
        local code = lower:sub(first, last)
        local iterator = env.personal.user_dict:lookup_words(code, true, 1)
        local has_prefix = false
        for _ in iterator:iter() do has_prefix = true; break end
        if not has_prefix then break end
        if env.personal:user_lookup(code, false) then
          for entry in env.personal:iter_user() do
            local exact = entry.custom_code and entry.custom_code:gsub(" +$", "")
            local key = tostring(first) .. "\0" .. code .. "\0" .. (entry.text or "")
            if exact == code and entry.commit_count > 0 and not env.short_conflicts[code]
                and entry.text and entry.text:match("^[!-~]+$")
                and not seen[key] then
              seen[key] = true
              matches[#matches + 1] = {
                first = first, last = last, code = code, text = entry.text,
                commits = math.min(3, entry.commit_count)
              }
            end
          end
        end
      end
    end
  end
  table.sort(matches, function(a, b)
    if a.first ~= b.first then return a.first < b.first end
    if #a.code ~= #b.code then return #a.code > #b.code end
    return a.text < b.text
  end)
  env.personal_input, env.personal_matches = input, matches
  return matches
end

local function yield_personal(input, segment, env)
  for _, match in ipairs(personal_matches(input, env)) do
    -- The compiled prism cannot acquire arbitrary user codes at runtime. Replace
    -- the exact personal span with an equal-length admitted one-letter syllable,
    -- then let the native mixed script translator segment and compose the whole
    -- sentence. The ShadowCandidate restores only the user-confirmed display.
    local carrier = string.rep("D", #match.code)
    local transformed = input:sub(1, match.first - 1) .. carrier .. input:sub(match.last + 1)
    local translation = env.translator:query(transformed, segment)
    if translation then
      for candidate in translation:iter() do
        if candidate._end < segment._end then break end
        local first, last = candidate.text:find(carrier, 1, true)
        if candidate.start == segment.start and candidate._end == segment._end
            and first and not candidate.text:find(carrier, last + 1, true)
            and not candidate.text:sub(first - 1, first - 1):find("[A-Za-z]")
            and not candidate.text:sub(last + 1, last + 1):find("[A-Za-z]")
            and candidate.text:find("[\128-\255]") then
          local text = candidate.text:sub(1, first - 1) .. match.text .. candidate.text:sub(last + 1)
          local shadow = ShadowCandidate(candidate, "mixed_personal_" .. tostring(match.commits), text, "", true)
          shadow.quality = -0.5
          yield(shadow)
        end
      end
    end
  end
end

function M.func(input, segment, env)
  local translation = env.translator:query(input, segment)
  if translation then
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
        local shadow = ShadowCandidate(candidate, "mixed_exact", candidate.text, candidate.comment or "", true)
        shadow.quality = -0.5
        yield(shadow)
      end
    end
  end
  yield_personal(input, segment, env)
end

return M
