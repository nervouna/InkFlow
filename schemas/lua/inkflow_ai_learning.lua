-- Writer for the ordinary Pinyin user dictionary. No independent candidate stream.
local M = {}

-- Lua Memory inherits native commit/key callbacks. Keeping its user_dict alive
-- between callbacks would prematurely commit ordinary undoable learning.
local function with_memory(env, operation)
  local memory
  local ok, result = pcall(function()
    memory = Memory(env.engine, env.engine.schema, "translator")
    return operation(memory)
  end)
  -- Clear native dictionary handles even when an operation fails. The remaining
  -- callbacks then return immediately until Lua GC destroys/disconnects the object.
  if memory then memory:disconnect() end
  return ok, result
end

local function readings(env, context, input, text, memory)
  local path = context:get_property("inkflow_ai_reverse_path")
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

function M.init(env)
  env.connection = env.engine.context.property_update_notifier:connect(function(context, name)
    if name == "inkflow_ai_readings" then
      local input, text = context:get_property(name):match("^([^\t]*)\t([^\t\r\n]+)$")
      if input and text then
        local ok, result = with_memory(env, function(memory)
          return readings(env, context, input, text, memory)
        end)
        context:set_property("inkflow_ai_readings_result", ok and result or "")
      end
      return
    end
    if name ~= "inkflow_ai_learning" then return end
    local payload = context:get_property(name)
    if payload == "" then return end
    local code, text = payload:match("^([a-z ]+ )\t([^\t\r\n]+)$")
    if not code or not text then return end
    local ok, updated = with_memory(env, function(memory)
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
    context:set_property("inkflow_ai_learning_result", ok and updated and "ok" or "failed")
  end)
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
end

function M.func() end

return M
