-- Read only already materialized native candidates. Return bounded, content-free
-- page metadata; no candidate or context text crosses this bridge.
local channel = require("inkflow_channel")
local M = {}

local function candidate_metadata(candidate, input_length)
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
  elseif candidate_type:match("^mixed_personal_[123]$") then
    source, exact, personal = "m", 1, tonumber(candidate_type:sub(-1))
  end
  if candidate_type == "uniquified" then
    -- Native deduplication preserves genuine candidates. Read existing evidence
    -- only when it describes this exact displayed text and input span. Do not
    -- prepare translations or reinterpret a merged phrase as learnable input.
    local items = candidate:get_genuines()
    if #items <= 256 then
      for _, item in ipairs(items) do
        if item.start == candidate.start and item._end == candidate._end
            and item.text == candidate.text then
          local kind = item.type or ""
          if kind == "user_table" then
            source, personal = "c", 0
          elseif source ~= "c" and kind:match("^mixed_personal_[123]$") then
            source, exact, personal = "m", 1, math.max(personal, tonumber(kind:sub(-1)))
          end
        end
      end
    end
  end
  local has_letter = candidate.text:find("[A-Za-z]") ~= nil
  local has_non_ascii = candidate.text:find("[\128-\255]") ~= nil
  local class = has_letter and (has_non_ascii and "m" or "a") or (has_non_ascii and "n" or "o")
  return table.concat({candidate.start, candidate._end, class, exact, personal, source}, ",")
end

local function input_coverage(fields, context)
  if #fields ~= 2 or not fields[1]:match("^%d+$") or not fields[2]:match("^%d+$") then return "failed" end
  local offset, count = tonumber(fields[1]), tonumber(fields[2])
  if count < 1 or count > 9 then return "failed" end
  local segment = context.composition:back()
  if not segment or not segment.menu then return "failed" end
  local menu = segment.menu
  -- get_candidate_at can prepare more translations; never request unmaterialized rows.
  if offset + count > menu:candidate_count() then return "failed" end
  local rows = {fields[1] .. "," .. fields[2]}
  for index = offset, offset + count - 1 do
    local candidate = menu:get_candidate_at(index)
    if not candidate then return "failed" end
    rows[#rows + 1] = candidate_metadata(candidate, #context.input)
  end
  return "ok", table.concat(rows, ";")
end

function M.init(env)
  env.connection = env.engine.context.property_update_notifier:connect(
    channel.observer({ input_coverage = input_coverage }))
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
end

-- This translator only hosts the property observer; native translators own candidates.
function M.func() end

return M
