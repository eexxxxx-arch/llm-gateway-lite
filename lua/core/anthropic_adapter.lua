-- Anthropic Messages API 适配器
-- 将 OpenAI Chat Completions 格式与 Anthropic Messages 格式相互转换，
-- 让网关对外保持 OpenAI 兼容 API，对内可以路由到 Anthropic 原生接口。
local cjson = require('cjson.safe')

local _M = {}

-- Anthropic Messages 端点（用户也可在 provider.endpoints.chat_completions 中覆盖）
_M.default_endpoint = '/v1/messages'
-- 默认 API 版本头
_M.default_version = '2023-06-01'
-- 当请求未指定 max_tokens 时使用的默认值（Anthropic 必填该字段）
_M.default_max_tokens = 4096

local function is_anthropic(provider)
  return provider and provider.type == 'anthropic'
end
_M.is_anthropic = is_anthropic

-- 把 OpenAI message.content 转成 Anthropic 接受的 content（字符串或 content block 数组）
-- Anthropic 原生支持：
--   "text" 字符串
--   数组：{type:"text", text:"..."} / {type:"image", source:{...}}
-- OpenAI 文本 block（{type:"text", text:"..."}）与 Anthropic 一致，可直接透传。
-- OpenAI 图片 block（{type:"image_url", image_url:{url:"..."}}）需要转换。
local function convert_content(content)
  if type(content) == 'string' then
    return content
  end
  if type(content) ~= 'table' then
    return ''
  end

  -- 数组形式
  local out = {}
  for _, block in ipairs(content) do
    if type(block) == 'string' then
      table.insert(out, { type = 'text', text = block })
    elseif type(block) == 'table' then
      if block.type == 'text' then
        -- 直接透传
        table.insert(out, { type = 'text', text = block.text or '' })
      elseif block.type == 'image_url' then
        -- OpenAI: {type:"image_url", image_url:{url:"data:image/png;base64,xxxx"}}
        local url = block.image_url and block.image_url.url
        if type(url) == 'string' then
          -- data URL: data:image/png;base64,XXXX
          local mime, data = url:match('^data:([^;]+);base64,(.+)$')
          if mime and data then
            local ext = mime:match('^image/(.+)$') or 'png'
            table.insert(out, {
              type = 'image',
              source = {
                type = 'base64',
                media_type = 'image/' .. ext,
                data = data,
              },
            })
          else
            -- HTTP URL：Anthropic 支持 url source
            table.insert(out, {
              type = 'image',
              source = { type = 'url', url = url },
            })
          end
        end
      else
        -- 其他类型透传，由 Anthropic 校验
        table.insert(out, block)
      end
    end
  end
  return out
end

-- 把 OpenAI 请求体转换为 Anthropic Messages 请求体
function _M.translate_request(body, provider)
  if type(body) ~= 'table' then
    return body
  end

  local out = {}
  out.model = body.model
  out.max_tokens = tonumber(body.max_tokens) or _M.default_max_tokens

  if body.temperature ~= nil then out.temperature = body.temperature end
  if body.top_p ~= nil then out.top_p = body.top_p end
  if body.top_k ~= nil then out.top_k = body.top_k end
  if body.stop ~= nil then
    if type(body.stop) == 'string' then
      out.stop_sequences = { body.stop }
    elseif type(body.stop) == 'table' then
      out.stop_sequences = body.stop
    end
  end
  if body.stream == true then out.stream = true end
  if body.user ~= nil then out.metadata = { user_id = tostring(body.user) } end

  -- 提取 system 消息到顶层 system 字段
  local system_parts = {}
  local messages = {}
  for _, msg in ipairs(body.messages or {}) do
    local role = msg.role
    if role == 'system' then
      if type(msg.content) == 'string' then
        table.insert(system_parts, msg.content)
      elseif type(msg.content) == 'table' then
        for _, block in ipairs(msg.content) do
          if type(block) == 'string' then
            table.insert(system_parts, block)
          elseif type(block) == 'table' and block.type == 'text' then
            table.insert(system_parts, block.text or '')
          end
        end
      end
    elseif role == 'tool' then
      -- OpenAI tool 消息 → Anthropic user 消息包含 tool_result
      local tool_call_id = msg.tool_call_id
      local text_content = ''
      if type(msg.content) == 'string' then
        text_content = msg.content
      elseif type(msg.content) == 'table' then
        text_content = cjson.encode(msg.content)
      end
      table.insert(messages, {
        role = 'user',
        content = {
          {
            type = 'tool_result',
            tool_use_id = tool_call_id,
            content = text_content,
          },
        },
      })
    elseif role == 'assistant' then
      -- 透传 assistant 消息；若包含 tool_calls，转换为 tool_use block
      local content = convert_content(msg.content)
      if msg.tool_calls and type(msg.tool_calls) == 'table' then
        local blocks = {}
        if type(content) == 'string' then
          if content ~= '' then
            table.insert(blocks, { type = 'text', text = content })
          end
        elseif type(content) == 'table' then
          for _, b in ipairs(content) do
            table.insert(blocks, b)
          end
        end
        for _, call in ipairs(msg.tool_calls) do
          local fn = call['function'] or {}
          local args = fn.arguments
          if type(args) == 'string' then
            local parsed = cjson.decode(args)
            args = parsed or args
          end
          table.insert(blocks, {
            type = 'tool_use',
            id = call.id,
            name = fn.name,
            input = args or {},
          })
        end
        content = blocks
      end
      table.insert(messages, { role = 'assistant', content = content })
    else
      -- user 消息透传（content 已转换）
      table.insert(messages, { role = role or 'user', content = convert_content(msg.content) })
    end
  end

  if #system_parts > 0 then
    out.system = table.concat(system_parts, '\n\n')
  end
  out.messages = messages

  -- 注入 tools / tool_choice（OpenAI 与 Anthropic 字段名不同）
  if body.tools and type(body.tools) == 'table' and #body.tools > 0 then
    local tools = {}
    for _, t in ipairs(body.tools) do
      if t['function'] then
        table.insert(tools, {
          name = t['function'].name,
          description = t['function'].description,
          input_schema = t['function'].parameters or { type = 'object', properties = {} },
        })
      end
    end
    if #tools > 0 then out.tools = tools end
  end
  if body.tool_choice ~= nil then
    local tc = body.tool_choice
    if type(tc) == 'string' then
      if tc == 'auto' or tc == 'none' then
        out.tool_choice = { type = tc }
      end
    elseif type(tc) == 'table' and tc.type == 'function' and tc['function'] then
      out.tool_choice = { type = 'tool', name = tc['function'].name }
    end
  end

  -- 应用 provider.request_defaults（除 model 外）
  local defaults = provider and provider.request_defaults or {}
  if type(defaults) == 'table' then
    for k, v in pairs(defaults) do
      if k ~= 'model' and out[k] == nil then
        out[k] = v
      end
    end
  end

  return out
end

-- 把 Anthropic stop_reason 映射为 OpenAI finish_reason
local function map_stop_reason(reason)
  if reason == 'end_turn' or reason == 'stop_sequence' then
    return 'stop'
  elseif reason == 'max_tokens' then
    return 'length'
  elseif reason == 'tool_use' then
    return 'tool_calls'
  end
  return reason or 'stop'
end

-- 把 Anthropic 非流式响应转换为 OpenAI Chat Completion 响应
function _M.translate_response(raw_body, provider_model, channel)
  if type(raw_body) ~= 'string' or raw_body == '' then
    return raw_body
  end

  local decoded = cjson.decode(raw_body)
  if type(decoded) ~= 'table' then
    return raw_body
  end

  local text_parts = {}
  local tool_calls = {}
  if type(decoded.content) == 'table' then
    for _, block in ipairs(decoded.content) do
      if type(block) == 'table' then
        if block.type == 'text' then
          table.insert(text_parts, block.text or '')
        elseif block.type == 'tool_use' then
          local args_json = cjson.encode(block.input or {})
          table.insert(tool_calls, {
            id = block.id,
            type = 'function',
            ['function'] = {
              name = block.name,
              arguments = args_json,
            },
          })
        end
      end
    end
  end

  local finish_reason = map_stop_reason(decoded.stop_reason)
  local message = {
    role = 'assistant',
    content = table.concat(text_parts, ''),
  }
  if #tool_calls > 0 then
    message.tool_calls = tool_calls
    -- 当有 tool_calls 时，OpenAI 习惯把 content 设为 nil
    if message.content == '' then
      message.content = nil
    end
  end

  local usage = decoded.usage or {}
  local openai_response = {
    id = decoded.id or ('chatcmpl-' .. tostring(os.time())),
    object = 'chat.completion',
    created = os.time(),
    model = provider_model or decoded.model,
    choices = {
      {
        index = 0,
        message = message,
        finish_reason = finish_reason,
      },
    },
    usage = {
      prompt_tokens = usage.input_tokens or 0,
      completion_tokens = usage.output_tokens or 0,
      total_tokens = (usage.input_tokens or 0) + (usage.output_tokens or 0),
    },
  }

  if channel then
    openai_response.channel = channel
  end

  return cjson.encode(openai_response)
end

-- 把 Anthropic 错误响应包装为 OpenAI 错误响应格式
function _M.translate_error_response(raw_body)
  if type(raw_body) ~= 'string' or raw_body == '' then
    return raw_body
  end
  local decoded = cjson.decode(raw_body)
  if type(decoded) ~= 'table' then
    return raw_body
  end
  -- Anthropic: {"type":"error","error":{"type":"...","message":"..."}}
  -- OpenAI:    {"error":{"message":"...","type":"...","code":null}}
  if decoded.error and type(decoded.error) == 'table' and decoded.error.message then
    local payload = {
      error = {
        message = decoded.error.message,
        type = decoded.error.type or 'api_error',
        code = decoded.error.code or nil,
      },
    }
    return cjson.encode(payload)
  end
  return raw_body
end

-- 流式翻译器：消费 Anthropic SSE 事件，产出 OpenAI SSE chunk（不含 "data: " 前缀）。
-- 返回的表有 handle_event(event_type, data_tbl) 方法，返回值是字符串或 nil。
function _M.new_stream_translator(provider_model, request_id)
  local state = {
    model = provider_model,
    created = os.time(),
    chunk_id = 'chatcmpl-' .. (request_id or tostring(os.time())),
    role_sent = false,
    tool_call_index = 0,
    active_tool_id = nil,
    active_tool_name = nil,
  }

  local function make_chunk(delta, finish_reason)
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
    return cjson.encode(chunk)
  end

  local function handle_event(event_type, data)
    if not event_type then return nil end

    if event_type == 'message_start' then
      if not state.role_sent then
        state.role_sent = true
        return make_chunk({ role = 'assistant' }, nil)
      end
      return nil
    elseif event_type == 'content_block_start' then
      local block = data and data.content_block
      if block and block.type == 'tool_use' then
        state.active_tool_id = block.id
        state.active_tool_name = block.name
        local idx = state.tool_call_index
        state.tool_call_index = idx + 1
        return make_chunk({
          tool_calls = {
            {
              index = idx,
              id = block.id,
              type = 'function',
              ['function'] = { name = block.name, arguments = '' },
            },
          },
        }, nil)
      end
      return nil
    elseif event_type == 'content_block_delta' then
      local delta = data and data.delta
      if not delta then return nil end
      if delta.type == 'text_delta' and delta.text then
        return make_chunk({ content = delta.text }, nil)
      elseif delta.type == 'input_json_delta' and delta.partial_json then
        if state.active_tool_id then
          local idx = state.tool_call_index - 1
          if idx < 0 then idx = 0 end
          return make_chunk({
            tool_calls = {
              {
                index = idx,
                id = state.active_tool_id,
                type = 'function',
                ['function'] = { name = state.active_tool_name or '', arguments = delta.partial_json },
              },
            },
          }, nil)
        end
      end
      return nil
    elseif event_type == 'content_block_stop' then
      state.active_tool_id = nil
      state.active_tool_name = nil
      return nil
    elseif event_type == 'message_delta' then
      local delta = data and data.delta
      if delta and delta.stop_reason then
        return make_chunk({}, map_stop_reason(delta.stop_reason))
      end
      return nil
    end
    return nil
  end

  return {
    handle_event = handle_event,
  }
end

-- 构造 Anthropic 鉴权头
function _M.build_auth_headers(provider, key)
  local headers = {}
  headers['x-api-key'] = (key and key.value) or ''
  headers['anthropic-version'] = (provider and provider.anthropic_version) or _M.default_version
  return headers
end

return _M
