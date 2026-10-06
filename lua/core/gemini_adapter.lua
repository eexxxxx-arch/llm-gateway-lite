-- Google Gemini 原生 API 适配器
-- 将 OpenAI Chat Completions 格式与 Gemini 原生 generateContent 格式相互转换，
-- 让网关对外保持 OpenAI 兼容 API，对内可以路由到 Gemini 原生端点。
--
-- 与 Anthropic 适配器的关键差异：
--   1. model 不在请求体里，而在 URL path 中：/v1beta/models/{model}:generateContent
--      （流式为 :streamGenerateContent?alt=sse，必须带 alt=sse，否则返回 JSON 数组而非 SSE）
--   2. 鉴权使用 x-goog-api-key 头部（而非 Authorization Bearer）
--   3. 响应的 usageMetadata 与 finishReason 枚举不同
--   4. 流式响应中每个 SSE data 是完整的 GenerateContentResponse（非 delta 语义），
--      functionCall 整块到达（无 arguments 流式增量），且不发送 [DONE]（由网关补发）
--   5. thoughtSignature 是协议一等字段（parts[].thoughtSignature），
--      捕获/回注直接在适配器内完成，复用 gemini_signature 的 shared dict 缓存
local cjson = require('cjson.safe')
local gemini_sig = require('core.gemini_signature')

local _M = {}

-- 非流式/流式端点默认模板（可用 provider.endpoints 覆盖，需包含 {model} 占位符）
_M.default_endpoint = '/models/{model}:generateContent'
_M.default_endpoint_stream = '/models/{model}:streamGenerateContent?alt=sse'

-- JSON Schema 中 Gemini 不支持或多余的关键字（丢弃处理；
-- Gemini 对未知字段的宽容度不定，白名单式转换最稳）
local SCHEMA_DROP_KEYS = {
  ['$schema'] = true,
  ['$id'] = true,
  ['$ref'] = true,
  ['$defs'] = true,
  ['definitions'] = true,
  ['additionalProperties'] = true,
  ['additionalItems'] = true,
  ['strict'] = true,
  ['default'] = true,
  ['examples'] = true,
  ['patternProperties'] = true,
  ['propertyNames'] = true,
  ['dependencies'] = true,
  ['exclusiveMinimum'] = true,
  ['exclusiveMaximum'] = true,
  ['multipleOf'] = true,
  ['uniqueItems'] = true,
  ['minProperties'] = true,
  ['maxProperties'] = true,
  ['minLength'] = true,
  ['maxLength'] = true,
  ['minItems'] = true,
  ['maxItems'] = true,
}

function _M.is_gemini(provider)
  return provider and provider.type == 'gemini'
end

-- 构造上游 URL：model 在 path 中
-- 优先使用 provider.endpoints 中的模板（需含 {model}），否则用内置默认
function _M.build_url(provider, provider_model, is_stream)
  local base = (tostring(provider and provider.base_url or ''):gsub('/+$', ''))
  local model = tostring(provider_model or '')

  local endpoints = provider and provider.endpoints or nil
  local tpl = nil
  if type(endpoints) == 'table' then
    tpl = is_stream and endpoints.chat_completions_stream or endpoints.chat_completions
  end
  if type(tpl) == 'string' and tpl:find('{model}', 1, true) then
    local url = base .. (tpl:gsub('{model}', model))
    -- 流式模板未带 alt=sse 时自动补上（缺省时返回 JSON 数组而非 SSE 流）
    if is_stream and not url:find('alt=sse', 1, true) then
      url = url .. (url:find('?', 1, true) and '&' or '?') .. 'alt=sse'
    end
    return url
  end

  return base .. (is_stream and _M.default_endpoint_stream or _M.default_endpoint):gsub('{model}', model)
end

-- 构造鉴权头：Gemini 原生使用 x-goog-api-key
function _M.build_auth_headers(provider, key)
  return { ['x-goog-api-key'] = (key and key.value) or '' }
end

-- ------------------------------------------------------------------
-- 请求转换：OpenAI Chat Completions → Gemini GenerateContent
-- ------------------------------------------------------------------

-- 递归净化 JSON Schema：大写 type、数组类型转 nullable、丢弃不支持的关键字
local function sanitize_schema(node)
  if type(node) ~= 'table' then
    return node
  end

  local out = {}
  local t = node.type
  if type(t) == 'table' then
    -- JSON Schema 数组类型（如 ["string","null"]）→ 主类型 + nullable
    local primary, nullable = nil, false
    for _, v in ipairs(t) do
      if v == 'null' then
        nullable = true
      else
        primary = v
      end
    end
    if primary then out.type = string.upper(tostring(primary)) end
    if nullable then out.nullable = true end
  elseif type(t) == 'string' then
    out.type = string.upper(t)
  end

  for k, v in pairs(node) do
    if k == 'type' then
      -- 已在上方处理
    elseif k == 'properties' and type(v) == 'table' then
      local props = {}
      for name, sub in pairs(v) do
        props[name] = sanitize_schema(sub)
      end
      out.properties = props
    elseif k == 'items' then
      out.items = sanitize_schema(v)
    elseif k == 'anyOf' or k == 'oneOf' then
      local arr = {}
      for i, sub in ipairs(v) do
        arr[i] = sanitize_schema(sub)
      end
      out[k] = arr
    elseif SCHEMA_DROP_KEYS[k] then
      -- 丢弃 Gemini 不支持的关键字
    elseif k == 'required' or k == 'enum' or k == 'format' or k == 'description'
        or k == 'title' or k == 'minimum' or k == 'maximum' or k == 'nullable'
        or k == 'propertyOrdering' or k == 'example' or k == 'allOf' then
      out[k] = v
    end
    -- 其余未知字段丢弃
  end
  return out
end

-- OpenAI tools[] → Gemini tools[{functionDeclarations=[...]}]
local function translate_tools(tools)
  if type(tools) ~= 'table' or #tools == 0 then
    return nil
  end
  local decls = {}
  for _, t in ipairs(tools) do
    if type(t) == 'table' and type(t['function']) == 'table' then
      local fn = t['function']
      local decl = {
        name = fn.name or '',
        description = fn.description or '',
      }
      if type(fn.parameters) == 'table' then
        decl.parameters = sanitize_schema(fn.parameters)
      end
      table.insert(decls, decl)
    end
  end
  if #decls == 0 then
    return nil
  end
  return { { functionDeclarations = decls } }
end

-- OpenAI tool_choice → Gemini toolConfig.functionCallingConfig
local function translate_tool_choice(tc)
  if type(tc) == 'string' then
    if tc == 'auto' then
      return { functionCallingConfig = { mode = 'AUTO' } }
    elseif tc == 'none' then
      return { functionCallingConfig = { mode = 'NONE' } }
    elseif tc == 'required' then
      return { functionCallingConfig = { mode = 'ANY' } }
    end
  elseif type(tc) == 'table' and tc.type == 'function'
      and type(tc['function']) == 'table' and tc['function'].name then
    return { functionCallingConfig = { mode = 'ANY', allowedFunctionNames = { tc['function'].name } } }
  end
  return nil
end

-- 合成 OpenAI 风格的 tool_call id（Gemini 原生 functionCall 无 id）
local function synthesize_tool_call_id()
  local seed = tostring(ngx.now()) .. '-' .. tostring(math.random(1000000, 9999999))
  return 'call_' .. ngx.md5(seed)
end

-- 提取 content（字符串或 block 数组）中的纯文本，用于 system 消息与 functionResponse 兜底
local function text_from_content(content)
  if type(content) == 'string' then
    return content
  end
  if type(content) ~= 'table' then
    return ''
  end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == 'string' then
      table.insert(parts, block)
    elseif type(block) == 'table' and block.type == 'text' then
      table.insert(parts, block.text or '')
    end
  end
  return table.concat(parts, '')
end

-- OpenAI message.content → Gemini parts 数组（user/assistant 消息路径）
-- 文本透传；图片仅支持 data URL（inlineData），HTTP URL 需走 File API，跳过并告警
local function convert_parts(content)
  local parts = {}
  if type(content) == 'string' then
    if content ~= '' then
      table.insert(parts, { text = content })
    end
    return parts
  end
  if type(content) ~= 'table' then
    return parts
  end
  for _, block in ipairs(content) do
    if type(block) == 'string' then
      table.insert(parts, { text = block })
    elseif type(block) == 'table' then
      if block.type == 'text' then
        table.insert(parts, { text = block.text or '' })
      elseif block.type == 'image_url' then
        local url = block.image_url and block.image_url.url
        if type(url) == 'string' then
          local mime, data = url:match('^data:([^;]+);base64,(.+)$')
          if mime and data then
            table.insert(parts, { inlineData = { mimeType = mime, data = data } })
          else
            ngx.log(ngx.WARN, '[gemini_adapter] skip non-data image_url: native API requires inlineData or File API upload')
          end
        end
      end
      -- 其他 block 类型（audio 等）暂不支持，跳过
    end
  end
  return parts
end

function _M.translate_request(body, provider)
  if type(body) ~= 'table' then
    return {}
  end

  local contents = {}
  local system_parts = {}
  -- tool_call_id → function name 映射：OpenAI tool 消息只带 tool_call_id，
  -- 而 Gemini functionResponse 必须给出函数名，需回看前面 assistant 的 tool_calls
  local tool_call_names = {}

  for _, msg in ipairs(body.messages or {}) do
    local role = msg.role
    if role == 'system' or role == 'developer' then
      -- system 消息 → 顶层 systemInstruction
      local text = text_from_content(msg.content)
      if text ~= '' then
        table.insert(system_parts, text)
      end
    elseif role == 'tool' or role == 'function' then
      -- OpenAI tool 结果 → user 消息中的 functionResponse part
      local name = tool_call_names[msg.tool_call_id or ''] or msg.name or 'function'
      local response_value
      if type(msg.content) == 'string' then
        local decoded = cjson.decode(msg.content)
        if type(decoded) == 'table' then
          response_value = decoded
        else
          response_value = { result = msg.content }
        end
      elseif type(msg.content) == 'table' then
        local text = text_from_content(msg.content)
        if text ~= '' then
          local decoded = cjson.decode(text)
          response_value = (type(decoded) == 'table') and decoded or { result = text }
        else
          response_value = { result = cjson.encode(msg.content) or '' }
        end
      else
        response_value = { result = '' }
      end
      table.insert(contents, {
        role = 'user',
        parts = { { functionResponse = { name = name, response = response_value } } },
      })
    elseif role == 'assistant' then
      local parts = convert_parts(msg.content)
      if type(msg.tool_calls) == 'table' then
        for _, tc in ipairs(msg.tool_calls) do
          if type(tc) == 'table' and type(tc['function']) == 'table' then
            local fn = tc['function']
            if tc.id then
              tool_call_names[tc.id] = fn.name
            end
            -- arguments 是 JSON 字符串 → Gemini functionCall.args 需为对象
            local args = {}
            if type(fn.arguments) == 'string' and fn.arguments ~= '' then
              local decoded = cjson.decode(fn.arguments)
              if type(decoded) == 'table' then
                args = decoded
              end
            elseif type(fn.arguments) == 'table' then
              args = fn.arguments
            end
            local call_part = { functionCall = { name = fn.name or '', args = args } }
            -- 回注 thoughtSignature（原生协议：functionCall part 上的 thoughtSignature）
            local sig = gemini_sig.get_cached_signature(tc.id)
            if sig then
              call_part.thoughtSignature = sig
            end
            table.insert(parts, call_part)
          end
        end
      end
      if #parts > 0 then
        table.insert(contents, { role = 'model', parts = parts })
      end
    else
      -- user 等消息透传（content 已转换为 parts）
      local parts = convert_parts(msg.content)
      if #parts == 0 then
        parts = { { text = '' } }
      end
      table.insert(contents, { role = role or 'user', parts = parts })
    end
  end

  local out = {}
  if #contents > 0 then
    out.contents = contents
  end
  if #system_parts > 0 then
    out.systemInstruction = { parts = { { text = table.concat(system_parts, '\n\n') } } }
  end

  -- 采样参数 → generationConfig（camelCase）
  local gen = {}
  if body.max_tokens ~= nil then gen.maxOutputTokens = tonumber(body.max_tokens) end
  if body.temperature ~= nil then gen.temperature = tonumber(body.temperature) end
  if body.top_p ~= nil then gen.topP = tonumber(body.top_p) end
  if body.top_k ~= nil then gen.topK = tonumber(body.top_k) end
  if body.seed ~= nil then gen.seed = tonumber(body.seed) end
  if body.stop ~= nil then
    if type(body.stop) == 'string' then
      gen.stopSequences = { body.stop }
    elseif type(body.stop) == 'table' then
      gen.stopSequences = body.stop
    end
  end
  if body.n ~= nil and tonumber(body.n) and tonumber(body.n) > 1 then
    gen.candidateCount = tonumber(body.n)
  end
  local rf = body.response_format
  if type(rf) == 'table' then
    if rf.type == 'json_object' then
      gen.responseMimeType = 'application/json'
    elseif rf.type == 'json_schema' and type(rf.json_schema) == 'table' then
      gen.responseMimeType = 'application/json'
      if type(rf.json_schema.schema) == 'table' then
        gen.responseSchema = sanitize_schema(rf.json_schema.schema)
      end
    end
  end
  if next(gen) ~= nil then
    out.generationConfig = gen
  end

  local tools = translate_tools(body.tools)
  if tools then
    out.tools = tools
  end
  local tool_config = translate_tool_choice(body.tool_choice)
  if tool_config then
    out.toolConfig = tool_config
  end

  -- 应用 provider.request_defaults（除 model 外；表字段做一层深合并，
  -- 如 defaults.generationConfig.thinkingConfig 与请求级 temperature 并存）
  local defaults = provider and provider.request_defaults or {}
  if type(defaults) == 'table' then
    for k, v in pairs(defaults) do
      if k ~= 'model' then
        if out[k] == nil then
          out[k] = v
        elseif type(v) == 'table' and type(out[k]) == 'table' then
          for k2, v2 in pairs(v) do
            if out[k][k2] == nil then
              out[k][k2] = v2
            end
          end
        end
      end
    end
  end

  return out
end

-- ------------------------------------------------------------------
-- 响应转换：Gemini GenerateContent → OpenAI Chat Completion
-- ------------------------------------------------------------------

-- Gemini finishReason → OpenAI finish_reason
local function map_finish_reason(reason)
  if reason == 'STOP' then
    return 'stop'
  elseif reason == 'MAX_TOKENS' then
    return 'length'
  elseif reason == 'SAFETY' or reason == 'RECITATION' or reason == 'PROHIBITED_CONTENT'
      or reason == 'BLOCKLIST' or reason == 'SPII' or reason == 'SEXUALLY_EXPLICIT' then
    return 'content_filter'
  elseif reason == 'MALFORMED_FUNCTION_CALL' then
    return 'stop'
  end
  return reason or 'stop'
end

-- usageMetadata → OpenAI usage（thoughtsTokenCount 记入 reasoning_tokens 细分）
local function build_usage(um)
  if type(um) ~= 'table' then
    return { prompt_tokens = 0, completion_tokens = 0, total_tokens = 0 }
  end
  local prompt_tokens = tonumber(um.promptTokenCount) or 0
  local completion_tokens = tonumber(um.candidatesTokenCount) or 0
  local total_tokens = tonumber(um.totalTokenCount) or (prompt_tokens + completion_tokens)
  local usage = {
    prompt_tokens = prompt_tokens,
    completion_tokens = completion_tokens,
    total_tokens = total_tokens,
  }
  local thoughts = tonumber(um.thoughtsTokenCount)
  local cached = tonumber(um.cachedContentTokenCount)
  if thoughts then
    usage.completion_tokens_details = { reasoning_tokens = thoughts }
  end
  if cached then
    usage.prompt_tokens_details = { cached_tokens = cached }
  end
  return usage
end

-- 遍历 parts，产出 OpenAI message 的文本与 tool_calls；同时捕获 thoughtSignature
-- 返回: text_parts(table), tool_calls(table)
local function extract_parts(parts)
  local text_parts = {}
  local tool_calls = {}
  if type(parts) ~= 'table' then
    return text_parts, tool_calls
  end
  for _, part in ipairs(parts) do
    if type(part) == 'table' then
      if type(part.functionCall) == 'table' then
        local args = part.functionCall.args
        local args_json = (type(args) == 'table' and cjson.encode(args)) or '{}'
        local call_id = synthesize_tool_call_id()
        table.insert(tool_calls, {
          id = call_id,
          type = 'function',
          ['function'] = {
            name = part.functionCall.name or '',
            arguments = args_json,
          },
        })
        -- 捕获 thoughtSignature 供下一轮回注（防 400 missing thought_signature）
        if part.thoughtSignature then
          gemini_sig.cache_signature(call_id, part.thoughtSignature)
        end
      elseif type(part.text) == 'string' then
        table.insert(text_parts, part.text)
      end
    end
  end
  return text_parts, tool_calls
end

-- 把 Gemini 非流式响应转换为 OpenAI Chat Completion 响应
function _M.translate_response(raw_body, provider_model, channel)
  if type(raw_body) ~= 'string' or raw_body == '' then
    return raw_body
  end

  local decoded = cjson.decode(raw_body)
  if type(decoded) ~= 'table' then
    return raw_body
  end
  -- 错误体保持原样，由 translate_error_response 统一处理
  if type(decoded.error) == 'table' then
    return raw_body
  end

  local cand = type(decoded.candidates) == 'table' and decoded.candidates[1] or nil
  local content = cand and type(cand.content) == 'table' and cand.content or nil
  local text_parts, tool_calls = extract_parts(content and content.parts or nil)

  local message = {
    role = 'assistant',
    content = table.concat(text_parts, ''),
  }
  if #tool_calls > 0 then
    message.tool_calls = tool_calls
    if message.content == '' then
      message.content = nil
    end
  end

  local openai_response = {
    id = decoded.responseId or ('chatcmpl-' .. tostring(os.time())),
    object = 'chat.completion',
    created = os.time(),
    model = provider_model or decoded.model,
    choices = {
      {
        index = 0,
        message = message,
        finish_reason = map_finish_reason(cand and cand.finishReason or nil),
      },
    },
    usage = build_usage(decoded.usageMetadata),
  }

  if channel then
    openai_response.channel = channel
  end

  return cjson.encode(openai_response)
end

-- 把 Gemini 错误响应包装为 OpenAI 错误响应格式
-- Gemini: {"error":{"code":400,"message":"...","status":"INVALID_ARGUMENT"}}
-- OpenAI: {"error":{"message":"...","type":"...","code":...}}
function _M.translate_error_response(raw_body)
  if type(raw_body) ~= 'string' or raw_body == '' then
    return raw_body
  end
  local decoded = cjson.decode(raw_body)
  if type(decoded) ~= 'table' then
    return raw_body
  end
  -- 兼容数组包裹（与 openai_compat.extract_error_signal 的 unwrap 逻辑对齐）
  if type(decoded[1]) == 'table' then
    decoded = decoded[1]
  end
  local err = type(decoded.error) == 'table' and decoded.error or nil
  if err and (err.message or err.status) then
    local payload = {
      error = {
        message = err.message or (err.status or 'unknown error'),
        type = err.status or 'api_error',
        code = err.code or nil,
      },
    }
    return cjson.encode(payload)
  end
  return raw_body
end

-- ------------------------------------------------------------------
-- 流式转换：消费 Gemini SSE（每个 data 是完整 GenerateContentResponse），
-- 产出 OpenAI SSE chunk（不含 "data: " 前缀）。
-- 返回的表有 handle_data(data_tbl) 方法，返回值是字符串（可含多行、每行一个
-- chunk JSON）或 nil；空行分隔由中继层负责。
-- ------------------------------------------------------------------
function _M.new_stream_translator(provider_model, request_id)
  local state = {
    model = provider_model,
    created = os.time(),
    chunk_id = 'chatcmpl-' .. ngx.md5(tostring(request_id or '') .. tostring(ngx.now())),
    role_sent = false,
    tool_call_index = 0,
    finished = false,
  }

  local function make_chunk(delta, finish_reason, usage)
    local chunk = {
      id = state.chunk_id,
      object = 'chat.completion.chunk',
      created = state.created,
      model = state.model,
      choices = {
        {
          index = 0,
          delta = delta,
          finish_reason = finish_reason,
        },
      },
    }
    if usage then
      chunk.usage = usage
    end
    return cjson.encode(chunk)
  end

  -- OpenAI 客户端期望首条 delta 带 role
  local function ensure_role(out)
    if not state.role_sent then
      state.role_sent = true
      table.insert(out, make_chunk({ role = 'assistant' }, nil, nil))
    end
  end

  local function handle_data(data)
    if type(data) ~= 'table' then
      return nil
    end
    -- 流内错误对象：记录日志，让流自然结束（与 anthropic 流错误处理策略一致）
    if type(data.error) == 'table' then
      ngx.log(ngx.WARN, '[gemini_adapter] stream error event: ', cjson.encode(data.error) or '')
      return nil
    end

    local cand = type(data.candidates) == 'table' and data.candidates[1] or nil
    if not cand then
      return nil
    end

    local out = {}
    local content = type(cand.content) == 'table' and cand.content or nil
    local parts = content and type(content.parts) == 'table' and content.parts or nil

    if parts then
      for _, part in ipairs(parts) do
        if type(part) == 'table' then
          if type(part.functionCall) == 'table' then
            -- functionCall 整块到达（无 arguments 流式增量），一次性发 tool_calls chunk
            local args = part.functionCall.args
            local args_json = (type(args) == 'table' and cjson.encode(args)) or '{}'
            local call_id = synthesize_tool_call_id()
            ensure_role(out)
            local idx = state.tool_call_index
            state.tool_call_index = idx + 1
            table.insert(out, make_chunk({
              tool_calls = {
                {
                  index = idx,
                  id = call_id,
                  type = 'function',
                  ['function'] = {
                    name = part.functionCall.name or '',
                    arguments = args_json,
                  },
                },
              },
            }, nil, nil))
            if part.thoughtSignature then
              gemini_sig.cache_signature(call_id, part.thoughtSignature)
            end
          elseif type(part.text) == 'string' and part.text ~= '' then
            ensure_role(out)
            table.insert(out, make_chunk({ content = part.text }, nil, nil))
          end
        end
      end
    end

    -- 最终 chunk 带 finishReason + usageMetadata
    if cand.finishReason and not state.finished then
      state.finished = true
      table.insert(out, make_chunk({}, map_finish_reason(cand.finishReason), build_usage(data.usageMetadata)))
    end

    if #out == 0 then
      return nil
    end
    return table.concat(out, '\n')
  end

  return {
    handle_data = handle_data,
  }
end

return _M
