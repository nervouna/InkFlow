-- Writer for the ordinary Pinyin user dictionary. No independent candidate stream.
local channel = require("inkflow_channel")
local M = {}

-- Lua Memory inherits native commit/key callbacks. Keeping its user_dict alive
-- between callbacks would prematurely commit ordinary undoable learning.
local function with_memory(env, operation)
  local memory
  local called, status, body = pcall(function()
    memory = Memory(env.engine, env.engine.schema, "translator")
    return operation(memory)
  end)
  -- Clear native dictionary handles even when an operation fails. The remaining
  -- callbacks then return immediately until Lua GC destroys/disconnects the object.
  if memory then memory:disconnect() end
  return called, status, body
end

local function readings(env, context, path, input, text, memory)
  if env.reverse_path ~= path then
    env.reverse = ReverseDb(path)
    env.reverse_path = path
  end
  local rows, seen = {}, {}
  for _, scalar in utf8.codes(text) do
    local character = utf8.char(scalar)
    if not seen[character] then
      seen[character] = true
      rows[#rows + 1] = "C\t" .. character .. "\t" .. env.reverse:lookup(character)
    end
  end
  -- Reuse the existing translator's menu: a second script translator would also
  -- attach ordinary learning callbacks. Probe only a bounded native candidate set.
  local segment = context.composition:back()
  if utf8.len(text) > 1 and context.input == input and segment and segment.start == 0 and segment.menu then
    segment.menu:prepare(128)
    for index = 0, 127 do
      local candidate = segment.menu:get_candidate_at(index)
      if not candidate then break end
      if candidate.text == text and candidate.start == 0 and candidate._end == #input then
        for _, genuine in ipairs(candidate:get_genuines()) do
          local phrase = genuine:to_phrase()
          if phrase and phrase.lang_name == memory.lang_name and genuine.type ~= "sentence" then
            rows[#rows + 1] = "P\t" .. table.concat(memory:decode(phrase.code), " ")
          end
        end
      end
    end
  end
  return table.concat(rows, "\n")
end

local function voice_lexicon(env)
  -- The Swift caller waits past the native undo window before reading: releasing
  -- a temporary UserDictionary commits any shared pending transaction. Never
  -- call this transport directly from a key callback or retain its raw pointer.
  local called, status, body = with_memory(env, function(memory)
    if not memory.user_dict or not memory.user_dict.loaded then return "unknown" end
    -- Empty predictive prefix caps accepted rows in native LookupWords, in key order:
    -- keep the cap above a typical user dictionary so later codes stay visible.
    local iterator = memory.user_dict:lookup_words("", true, 8192)
    local rows, bytes = {}, 3
    for entry in iterator:iter() do
      local text, code = entry.text, entry.custom_code
      if text and code and not text:find("[%c]") and code:match("^[a-z ]+$") then
        local row = text .. "\t" .. code .. "\t" .. tostring(entry.commit_count)
        if bytes + #row + 1 > 524288 then break end
        rows[#rows + 1] = row
        bytes = bytes + #row + 1
      end
    end
    return "ok", table.concat(rows, "\n") .. (#rows > 0 and "\n" or "")
  end)
  if not called then return "unknown" end
  return status, body
end

local function ai_readings(env, fields, context)
  local path, input, text = fields[1], fields[2], fields[3]
  if #fields ~= 3 or text == "" then return "failed" end
  local called, body = with_memory(env, function(memory)
    return readings(env, context, path, input, text, memory)
  end)
  if not called then return "failed" end
  return "ok", body
end

local function ai_learning(env, fields)
  local code, text = fields[1], fields[2]
  if #fields ~= 2 or not code:match("^[a-z ]+ $") or text == "" then return "failed" end
  local called, updated = with_memory(env, function(memory)
    if not memory:start_session() then return false end
    local written, result = pcall(function()
      local entry = DictEntry()
      entry.text = text
      entry.custom_code = code
      return memory:update_userdict(entry, 1, "")
    end)
    -- Always close the transaction, including a failed update.
    local finished = memory:finish_session()
    return written and result and finished
  end)
  return called and updated and "ok" or "failed"
end

function M.init(env)
  env.connection = env.engine.context.property_update_notifier:connect(channel.observer({
    voice_lexicon = function() return voice_lexicon(env) end,
    ai_readings = function(fields, context) return ai_readings(env, fields, context) end,
    ai_learning = function(fields) return ai_learning(env, fields) end,
  }))
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
end

function M.func() end

return M
