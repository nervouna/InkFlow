local channel = require("inkflow_channel")
local M = {}

local function corrected_spelling(memory, genuine, kind, candidate, input)
  if not memory or kind == "completion" then return 0 end
  local phrase = genuine:to_phrase()
  if not phrase or phrase.lang_name ~= memory.lang_name then return 0 end
  local syllables = memory:decode(phrase.code)
  if #syllables == 0 then return 0 end
  local typed = input:sub(candidate.start + 1, candidate._end):gsub("[ ']", "")
  return table.concat(syllables) ~= typed and 1 or 0
end

local function candidate_metadata(env, candidate, input, technical, pinyin)
  local input_length = #input
  local candidate_type = candidate.type or ""
  local source, exact, personal = "n", candidate._end == input_length and 1 or 0, 0
  if candidate_type == "user_table" then
    source = "c"
  elseif candidate_type == "english_exact" then
    source, exact = "e", 1
  elseif candidate_type == "english_completion" then
    source, exact = "e", 0
  elseif candidate_type:match("^english_personal_[123]$") then
    source, exact, personal = "e", 1, tonumber(candidate_type:sub(-1))
  elseif candidate_type == "mixed_exact" then
    source, exact = "m", 1
  elseif candidate_type:match("^mixed_personal_[0-3]$") then
    source, exact, personal = "m", 1, tonumber(candidate_type:sub(-1))
  end
  local genuine = candidate
  if candidate_type == "simplified" then
    genuine = candidate:get_genuine()
  end
  if candidate_type == "uniquified" then
    local items = candidate:get_genuines()
    genuine = items[1]
    if #items <= 256 then
      for _, item in ipairs(items) do
        if item.start == candidate.start and item._end == candidate._end
            and item.text == candidate.text then
          local kind = item.type or ""
          if kind == "user_table" then
            source, personal = "c", 0
          elseif source ~= "c" and kind:match("^mixed_personal_[0-3]$") then
            source, exact, personal = "m", 1, math.max(personal, tonumber(kind:sub(-1)))
          end
        end
      end
    end
  end
  if technical and source == "e" and exact == 1
      and candidate.start == 0 and candidate._end == input_length then
    exact = 2
  end
  if pinyin and source == "e" and exact == 1 and personal > 0
      and candidate.start == 0 and candidate._end == input_length then
    exact = 4
  end
  if candidate_type == "sentence" and exact == 1 and candidate.start == 0 then
    exact = 3
  end
  local kind = genuine.type or ""
  if #kind > 32 or not kind:match("^[a-z_][a-z0-9_]*$") then kind = "" end
  local called, corrected = pcall(corrected_spelling, env.memory, genuine, kind, candidate, input)
  local has_letter = candidate.text:find("[A-Za-z]") ~= nil
  local has_non_ascii = candidate.text:find("[\128-\255]") ~= nil
  local class = has_letter and (has_non_ascii and "m" or "a") or (has_non_ascii and "n" or "o")
  return table.concat({candidate.start, candidate._end, class, exact, personal, source, kind,
    called and corrected or 0}, ",")
end

local function input_coverage(env, fields, context)
  if #fields ~= 2 or not fields[1]:match("^%d+$") or not fields[2]:match("^%d+$") then return "failed" end
  local offset, count = tonumber(fields[1]), tonumber(fields[2])
  if count < 1 or count > 9 then return "failed" end
  local segment = context.composition:back()
  if not segment or not segment.menu then return "failed" end
  local menu = segment.menu
  if offset + count > menu:candidate_count() then return "failed" end
  local rows = {fields[1] .. "," .. fields[2]}
  local technical = context:get_property("inkflow_technical_input")
  technical = technical ~= "" and technical == context.input
  local pinyin = context:get_property("inkflow_pinyin_input")
  pinyin = pinyin ~= "" and pinyin == context.input
  for index = offset, offset + count - 1 do
    local candidate = menu:get_candidate_at(index)
    if not candidate then return "failed" end
    rows[#rows + 1] = candidate_metadata(env, candidate, context.input, technical, pinyin)
  end
  return "ok", table.concat(rows, ";")
end

function M.init(env)
  local created, memory = pcall(Memory, env.engine, env.engine.schema, "inkflow_input_coverage")
  env.memory = created and memory or nil
  env.connection = env.engine.context.property_update_notifier:connect(channel.observer({
    input_coverage = function(fields, context) return input_coverage(env, fields, context) end,
  }))
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
  env.memory = nil
end

function M.func() end

return M
