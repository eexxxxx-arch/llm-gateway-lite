local cjson = require('cjson.safe')
local runtime = require('config.runtime')
local normalize = require('core.normalize')
local router = require('core.router')
local keypool = require('core.keypool')
local rewrite = require('core.rewrite')
local errors = require('core.errors')
local observe = require('core.observe')
local http_client = require('core.http_client')
local auth = require('core.auth')
local anthropic = require('core.anthropic_adapter')
local gemini_sig = require('core.gemini_signature')

local _M = {}

local function safe_json_encode(obj)
  local ok, encoded = pcall(cjson.encode, obj)
  if ok then
    return encoded
  end
  return '{}'
end

local function format_timestamp()
  local now = ngx.now()
  local sec = math.floor(now)
  local msec = math.floor((now - sec) * 1000)
  return os.date('%Y-%m-%d %H:%M:%S', sec) .. string.format('.%03d', msec)
end

-- 脱敏敏感请求头（如 Authorization），返回浅拷贝避免污染原始表
local function sanitize_headers(headers)
  if type(headers) ~= 'table' then
    return headers
  end
  local sanitized = {}
  for k, v in pairs(headers) do
    if type(k) == 'string' and k:lower() == 'authorization' then
      sanitized[k] = '***'
    else
      sanitized[k] = v
    end
  end
  return sanitized
end

-- 截断过长的请求体，避免 error.log 单行被撑爆导致 response/error 被截掉
-- 完整 body 已由 log_upstream_request 写入 upstream.log，error.log 只保留头部用于上下文
local function truncate_body(body, max_len)
  max_len = max_len or 2048
  if type(body) ~= 'string' or #body <= max_len then
    return body
  end
  return body:sub(1, max_len) .. '...[truncated, total ' .. #body .. ' bytes]'
end

local function log_failed_request(provider, url, headers, request_body, res, req_err)
  -- response / error 放在 request 之前，且 request.body 做截断，
  -- 确保上游真正的报错不会被超长 body 挤出 error.log 的单行上限
  local log_entry = {
    timestamp = format_timestamp(),
    level = 'ERROR',
    event = 'upstream_request_failed',
    provider = provider.name,
    request_id = ngx.ctx.request_id,
    key_id = headers and headers['Authorization'] and '***' or nil,

    -- 响应信息（优先输出，便于排查上游真实报错）
    response = {
      status = res and res.status or nil,
      headers = res and res.headers or nil,
      body = res and res.body or nil,
    },

    -- 错误信息
    error = req_err,

    -- 请求信息（headers 脱敏；body 截断，完整 body 见 upstream.log）
    request = {
      url = url,
      method = 'POST',
      headers = sanitize_headers(headers),
      body = truncate_body(request_body),
    },
  }

  ngx.log(ngx.ERR, '[', format_timestamp(), '] ', cjson.encode(log_entry))
end

local function log_upstream_request(provider, url, headers, request_body)
  local log_entry = {
    timestamp = format_timestamp(),
    level = 'INFO',
    event = 'upstream_request',
    request_id = ngx.ctx.request_id,
    provider = provider and provider.name or nil,
    request = {
      url = url,
      method = 'POST',
      headers = sanitize_headers(headers),
      body = request_body,
    },
  }

  local line = cjson.encode(log_entry)
  if not line then
    return
  end

  local handle, err = io.open('/var/log/llm-gateway/upstream.log', 'a')
  if not handle then
    ngx.log(ngx.WARN, '[openai_compat] failed to open upstream.log: ', err or 'unknown error')
    return
  end
  handle:write(line, '\n')
  handle:close()
end

local hop_by_hop = {
  ['connection'] = true,
  ['keep-alive'] = true,
  ['proxy-authenticate'] = true,
  ['proxy-authorization'] = true,
  ['te'] = true,
  ['trailers'] = true,
  ['transfer-encoding'] = true,
  ['upgrade'] = true,
  ['content-length'] = true,
}

local function read_body()
  ngx.req.read_body()
  local data = ngx.req.get_body_data()
  if data then
    return data
  end
  local path = ngx.req.get_body_file()
  if not path then
    return nil
  end
  local handle = io.open(path, 'rb')
  if not handle then
    return nil
  end
  local content = handle:read('*a')
  handle:close()
  return content
end

local function join_url(base, path)
  if not path or path == '' then
    return base
  end
  local base_tail = base:sub(-1)
  local path_head = path:sub(1, 1)
  if base_tail == '/' and path_head == '/' then
    return base:sub(1, -2) .. path
  end
  if base_tail ~= '/' and path_head ~= '/' then
    return base .. '/' .. path
  end
  return base .. path
end

local function build_headers(provider, key, request_id)
  local headers = {
    ['Content-Type'] = 'application/json',
    ['Accept'] = 'application/json',
    ['Accept-Encoding'] = 'identity',
    ['User-Agent'] = 'llm-gateway-lite/0.1',
    ['X-Request-Id'] = request_id,
    ['Host'] = provider.host_header,
  }

  if anthropic.is_anthropic(provider) then
    -- Anthropic Messages API 使用 x-api-key + anthropic-version 头部
    local auth_headers = anthropic.build_auth_headers(provider, key)
    for name, value in pairs(auth_headers) do
      headers[name] = value
    end
  else
    local auth = provider.auth or {}
    local header_name = auth.header or 'Authorization'
    local prefix = auth.prefix or ''
    headers[header_name] = prefix .. (key.value or '')
  end

  if provider.headers then
    for name, value in pairs(provider.headers) do
      headers[name] = value
    end
  end

  return headers
end

-- 根据 provider 类型把 OpenAI 请求体编码为上游需要的 JSON 字符串
local function encode_body_for_provider(body, provider)
  if anthropic.is_anthropic(provider) then
    local translated = anthropic.translate_request(body, provider)
    local encoded, err = cjson.encode(translated)
    if not encoded then
      return nil, err or 'failed to encode anthropic body'
    end
    return encoded
  end
  return rewrite.encode_body(body)
end

local function copy_response_headers(headers)
  for name, value in pairs(headers or {}) do
    local key = name:lower()
    if not hop_by_hop[key] then
      ngx.header[name] = value
    end
  end
end

local function classify_error(status, err)
  if err then
    return 'upstream_error'
  end
  if not status then
    return 'upstream_error'
  end
  if status == 401 or status == 403 then
    return 'auth'
  end
  if status == 429 then
    return 'rate_limit'
  end
  if status >= 500 then
    return 'upstream_5xx'
  end
  if status >= 400 then
    return 'upstream_4xx'
  end
  return nil
end

local function inject_channel_to_json_response(raw_body, channel)
  if type(raw_body) ~= 'string' or raw_body == '' or not channel or channel == '' then
    return raw_body
  end

  local body_obj = cjson.decode(raw_body)
  if type(body_obj) ~= 'table' then
    return raw_body
  end

  body_obj.channel = channel
  local encoded = cjson.encode(body_obj)
  if not encoded then
    return raw_body
  end
  return encoded
end

local function deep_copy(value)
  if type(value) ~= 'table' then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function merge_defaults_into_body(body, defaults)
  for key, default_value in pairs(defaults) do
    if key ~= 'model' then
      local current_value = body[key]
      if current_value == nil then
        body[key] = deep_copy(default_value)
      elseif type(current_value) == 'table' and type(default_value) == 'table' then
        merge_defaults_into_body(current_value, default_value)
      end
    end
  end
end

local function apply_provider_request_defaults(body, provider)
  if type(body) ~= 'table' or type(provider) ~= 'table' then
    return
  end
  local defaults = provider.request_defaults
  if type(defaults) ~= 'table' then
    return
  end
  merge_defaults_into_body(body, defaults)
end

local function extract_error_signal(res)
  if not res or type(res.body) ~= 'string' or res.body == '' then
    return ''
  end

  local decoded = cjson.decode(res.body)
  if type(decoded) ~= 'table' then
    return string.lower(res.body)
  end

  local parts = {}
  local function push(v)
    if type(v) == 'string' and v ~= '' then
      table.insert(parts, string.lower(v))
    end
  end

  push(decoded.code)
  push(decoded.type)
  push(decoded.message)

  if type(decoded.error) == 'table' then
    push(decoded.error.code)
    push(decoded.error.type)
    push(decoded.error.message)
    push(decoded.error.param)
    if type(decoded.error.metadata) == 'table' then
      push(decoded.error.metadata.raw)
      push(decoded.error.metadata.limit_source)
      push(decoded.error.metadata.provider_error_code)
      push(decoded.error.metadata.remedy_hint)
      push(decoded.error.metadata.provider_name)
    end
  elseif type(decoded.error) == 'string' then
    push(decoded.error)
  end

  if type(decoded.detail) == 'string' then
    push(decoded.detail)
  end

  -- 兼容一些 provider 把 metadata 放顶层
  if type(decoded.metadata) == 'table' then
    push(decoded.metadata.limit_source)
    push(decoded.metadata.raw)
  end

  return table.concat(parts, ' ')
end

-- 从响应体中提取 openrouter 风格的结构化 metadata，用于更精细的决策
local function extract_error_metadata(res)
  local out = {
    limit_source = nil,      -- 'upstream_provider_shared_pool' | 'user' | 'provider' | nil
    is_byok = nil,           -- 是否带自有 key
    provider_error_code = nil,
    provider_name = nil,
    remedy_hint = nil,
    raw = nil,
  }
  if not res or type(res.body) ~= 'string' or res.body == '' then
    return out
  end
  local decoded = cjson.decode(res.body)
  if type(decoded) ~= 'table' then
    return out
  end
  local md = nil
  if type(decoded.error) == 'table' and type(decoded.error.metadata) == 'table' then
    md = decoded.error.metadata
  elseif type(decoded.metadata) == 'table' then
    md = decoded.metadata
  end
  if type(md) == 'table' then
    out.limit_source = type(md.limit_source) == 'string' and md.limit_source or nil
    out.is_byok = md.is_byok
    out.provider_error_code = type(md.provider_error_code) == 'string' and md.provider_error_code or nil
    out.provider_name = type(md.provider_name) == 'string' and md.provider_name or nil
    out.remedy_hint = type(md.remedy_hint) == 'string' and md.remedy_hint or nil
    out.raw = type(md.raw) == 'string' and md.raw or nil
  end
  return out
end

-- 从响应头中解析 Retry-After，返回秒数（nil 表示没有或无效）
local function extract_retry_after_sec(headers)
  if not runtime.respect_retry_after then
    return nil
  end
  if type(headers) ~= 'table' then
    return nil
  end
  local candidates = {
    headers['retry-after'],
    headers['Retry-After'],
    headers['x-ratelimit-reset'],
    headers['X-RateLimit-Reset'],
  }
  for _, v in ipairs(candidates) do
    if type(v) == 'string' and v ~= '' then
      local n = tonumber(v)
      if n and n > 0 and n < 86400 then
        return math.min(n, 3600) -- 上限 1 小时
      end
    end
  end
  return nil
end

-- 识别连接级错误（SSL 握手失败、连接拒绝、超时等）
-- 这类错误换 key 无意义，应该跳过当前 provider 剩余 key，直接换 provider
local function is_connection_error(err)
  if not err or type(err) ~= 'string' then
    return false
  end
  local lower = err:lower()
  return lower:find('handshake', 1, true)
    or lower:find('connection refused', 1, true)
    or lower:find('connection reset', 1, true)
    or lower:find('connection closed', 1, true)
    or lower:find('no such host', 1, true)
    or lower:find('timeout', 1, true)
    or lower:find('timed out', 1, true)
    or lower:find('proxy connect', 1, true)
end

-- 对 4xx/5xx 响应做结构化分析，返回给重试循环决策
-- 返回: {
--   cooldown_key: bool,              -- 是否需要冷却当前 key
--   cooldown_provider_model: bool,   -- 是否需要冷却 (provider,model)（共享池限流场景）
--   skip_same_provider: bool,        -- 是否跳过当前 provider 的其他 key（直接换 provider）
--   key_cooldown_sec: number|nil,    -- key 冷却秒数建议（nil = 使用 runtime 默认）
--   pm_cooldown_sec: number|nil,     -- provider-model 冷却秒数建议
-- }
local function analyze_error_for_retry(status, res, err)
  local default = {
    cooldown_key = false,
    cooldown_provider_model = false,
    skip_same_provider = false,
    key_cooldown_sec = nil,
    pm_cooldown_sec = nil,
  }
  if err then
    -- 连接级错误：换 key 无意义，跳过当前 provider 剩余 key，直接换 provider
    if is_connection_error(err) then
      local r = {
        cooldown_key = true,
        cooldown_provider_model = true,
        skip_same_provider = true,
        key_cooldown_sec = 10,
        pm_cooldown_sec = 30,
      }
      return r
    end
    -- 其他网络错误（非连接级）：不冷却 key，仅走重试逻辑
    return default
  end
  if not status then
    return default
  end

  if status == 401 or status == 402 or status == 403 then
    -- 鉴权 / 余额：强烈冷却 key，不涉及 provider-model
    local r = { cooldown_key = true, cooldown_provider_model = false, skip_same_provider = false }
    r.key_cooldown_sec = runtime.key_cooldown_sec
    return r
  end

  if status == 429 then
    local md = extract_error_metadata(res)
    local headers = res and res.headers or nil
    local retry_after = extract_retry_after_sec(headers)

    local r = {
      cooldown_key = true,
      cooldown_provider_model = false,
      skip_same_provider = false,
      key_cooldown_sec = runtime.key_rate_limit_cooldown_sec,
      pm_cooldown_sec = retry_after or runtime.provider_model_cooldown_sec,
    }

    -- 识别共享池限流：openrouter 特有 limit_source == upstream_provider_shared_pool
    -- 或 error message 中包含 "shared pool" / "rate-limited upstream" 等
    local signal = extract_error_signal(res)
    local is_shared_pool = (md.limit_source == 'upstream_provider_shared_pool')
      or (md.limit_source and md.limit_source:find('shared', 1, true))
      or (signal:find('shared pool', 1, true))
      or (signal:find('upstream_provider_shared_pool', 1, true))
      or (signal:find('rate%-limited upstream', 1, true))
      or (signal:find('temporarily rate%-limited', 1, true))

    if is_shared_pool then
      -- 共享池限流：换 key 没用，换 provider 才有用
      r.cooldown_provider_model = true
      r.skip_same_provider = true
      r.cooldown_key = false -- key 本身没问题，避免把 provider 的所有 key 都打冷却
      if retry_after then
        r.pm_cooldown_sec = math.max(retry_after, runtime.provider_model_cooldown_sec)
      end
    else
      -- 未命中共享池特征时：如果是 BYOK（用户自有 key），更倾向于只冷却 key 并等待
      if md.is_byok == true then
        r.cooldown_provider_model = false
        r.skip_same_provider = false
      end

      -- 区分配额耗尽（半永久，长冷却）与普通限流（瞬时，短冷却）
      -- 配额耗尽：insufficient_quota / allocated quota exceeded / quota limit
      -- 这种状态不会在几分钟内恢复，需要长冷却避免反复撞墙
      local is_quota_exhausted = signal:find('insufficient_quota', 1, true)
        or signal:find('quota exceeded', 1, true)
        or signal:find('allocated quota', 1, true)

      if is_quota_exhausted then
        r.key_cooldown_sec = runtime.key_quota_cooldown_sec
      elseif retry_after then
        r.key_cooldown_sec = math.max(retry_after, runtime.key_rate_limit_cooldown_sec)
      end
    end
    return r
  end

  if status >= 500 and status <= 599 then
    -- 5xx：一般不做 provider-model 级冷却，默认短 key 冷却或不冷却
    local r = { cooldown_key = false, cooldown_provider_model = false, skip_same_provider = false }
    local retry_after = extract_retry_after_sec(res and res.headers or nil)
    if retry_after and retry_after > 5 then
      r.cooldown_provider_model = true
      r.pm_cooldown_sec = retry_after
    end
    return r
  end

  -- 400 + 错误信号命中模式的：按 should_cooldown_key 的语义（由上层调用者判断）
  if status == 400 then
    if should_cooldown_key(status, res, nil) then
      return {
        cooldown_key = true,
        cooldown_provider_model = false,
        skip_same_provider = false,
        key_cooldown_sec = runtime.key_cooldown_sec,
      }
    end
  end

  return default
end

-- 指数退避 + jitter 睡眠（毫秒）。返回 true=睡过了，false=环境不支持睡眠
local function retry_backoff_sleep(attempt)
  local base = runtime.retry_backoff_base_ms
  if not base or base <= 0 then
    return false
  end
  -- attempt: 第几次重试（从 1 开始，说明已经失败过 1 次）
  local cap = 2000 -- 最大 2s
  local step = math.min(cap, base * math.pow(2, math.max(0, attempt - 1)))
  -- full jitter: 0 ~ step 之间均匀随机，避免惊群
  local ms = step * (math.random() or 0.5)
  if ms < 1 then
    return false
  end
  if ngx.sleep then
    -- OpenResty 的 ngx.sleep 支持亚毫秒（传秒的小数）
    ngx.sleep(ms / 1000.0)
    return true
  end
  return false
end

local function should_cooldown_key(status, res, err)
  if err then
    return false
  end
  if not status then
    return false
  end
  if status == 401 or status == 402 or status == 403 or status == 429 then
    return true
  end
  if status ~= 400 then
    return false
  end

  local signal = extract_error_signal(res)
  if signal == '' then
    return false
  end

  local patterns = {
    'insufficient_quota',
    'rate limit',
    'too many requests',
    'quota exceeded',
    'exceeded your current quota',
    'billing',
    'credit',
    'invalid api key',
    'api key',
    'authentication',
    'unauthorized',
    'token',
    '限流',
    '配额',
    '超限',
    '余额',
    '欠费',
  }
  for _, pattern in ipairs(patterns) do
    if signal:find(pattern, 1, true) then
      return true
    end
  end

  return false
end

local function should_retry(res, err)
  if err then
    return true
  end
  if not res or not res.status then
    return true
  end
  local status = res.status
  if status == 401 or status == 402 or status == 403 or status == 408 or status == 409 or status == 425 or status == 429 then
    return true
  end
  if status == 400 then
    return should_cooldown_key(status, res, err)
  end
  if status >= 500 and status <= 599 then
    return true
  end
  return false
end

local function do_request(provider, key, endpoint, body_json, request_id)
  local url = join_url(provider.base_url, endpoint)
  if ngx.var.args and ngx.var.args ~= '' then
    url = url .. '?' .. ngx.var.args
  end
  local headers = build_headers(provider, key, request_id)
  return http_client.request({
    url = url,
    method = 'POST',
    headers = headers,
    body = body_json,
    timeout_ms = provider.timeout_ms,
    ssl_verify = provider.ssl_verify,
    proxy_url = provider.proxy_url,
  })
end

local function relay_stream_response(stream_res, provider)
  if not stream_res then
    return nil, 'missing stream response'
  end

  -- Gemini 流式响应中捕获 thought_signature：解析 SSE data 行，按 tool_call.id 缓存
  local do_capture = gemini_sig.is_gemini_provider(provider)
  local sig_state = do_capture and gemini_sig.new_stream_state() or nil
  local line_buffer = ''

  while true do
    local chunk, chunk_err = stream_res.read_chunk()
    if chunk_err then
      return nil, chunk_err
    end
    if not chunk then
      return true
    end

    -- 捕获签名：解析完整的 SSE data 行（不修改原始 chunk，仅读取）
    if do_capture then
      line_buffer = line_buffer .. chunk
      while true do
        local s, e = line_buffer:find('\r?\n', 1)
        if not s then break end
        local line = line_buffer:sub(1, s - 1)
        line_buffer = line_buffer:sub(e + 1)
        local data_str = line:match('^data:%s*(.+)$')
        if data_str and data_str ~= '[DONE]' then
          local decoded = cjson.decode(data_str)
          if type(decoded) == 'table' then
            gemini_sig.capture_from_sse_data(sig_state, decoded)
          end
        end
      end
    end

    local ok, print_err = ngx.print(chunk)
    if not ok then
      return nil, print_err or 'failed to write chunk'
    end
    local ok_flush, flush_err = ngx.flush(true)
    if not ok_flush then
      return nil, flush_err or 'failed to flush chunk'
    end
  end
end

-- 解析 Anthropic SSE 流并转写成 OpenAI Chat Completion 的 SSE chunk。
-- 输入是 stream_res（http_client.request_stream 的返回值），输出通过 ngx.print/ngx.flush 发送。
local function relay_anthropic_stream(stream_res, provider_model, request_id)
  if not stream_res then
    return nil, 'missing stream response'
  end

  local translator = anthropic.new_stream_translator(provider_model, request_id)
  local buffer = ''
  -- 累积待发送的字符串
  local pending = {}

  local function flush_pending()
    if #pending == 0 then
      return true
    end
    local data = table.concat(pending)
    pending = {}
    local ok, print_err = ngx.print(data)
    if not ok then
      return nil, print_err or 'failed to write anthropic stream'
    end
    local ok_flush, flush_err = ngx.flush(true)
    if not ok_flush then
      return nil, flush_err or 'failed to flush anthropic stream'
    end
    return true
  end

  local function emit(payload)
    if payload and payload ~= '' then
      table.insert(pending, 'data: ' .. payload .. '\n\n')
    end
  end

  local function handle_event(event_type, data_str)
    local data = cjson.decode(data_str) or {}
    if event_type == 'error' then
      -- Anthropic 流中错误事件：记录日志，让流自然结束
      ngx.log(ngx.WARN, '[', format_timestamp(), '] [openai_compat] anthropic stream error event: ', data_str or '')
      return
    end
    emit(translator.handle_event(event_type, data))
  end

  -- 处理 buffer 中已完整的事件块（以空行分隔）
  local function process_buffer()
    while true do
      local start_idx, end_idx = buffer:find('\r?\n\r?\n', 1)
      if not start_idx then
        break
      end
      local block = buffer:sub(1, start_idx - 1)
      buffer = buffer:sub(end_idx + 1)

      local event_type = nil
      local data_lines = {}
      for line in block:gmatch('[^\r\n]+') do
        local prefix, rest = line:match('^(%a+):%s*(.*)$')
        if prefix == 'event' then
          event_type = rest
        elseif prefix == 'data' then
          table.insert(data_lines, rest)
        end
      end
      if event_type and #data_lines > 0 then
        handle_event(event_type, table.concat(data_lines, '\n'))
      end
    end
  end

  while true do
    local chunk, chunk_err = stream_res.read_chunk()
    if chunk_err then
      return nil, chunk_err
    end
    if not chunk then
      -- 流结束，处理剩余 buffer
      if buffer ~= '' then
        -- 尝试补一个空行让 process_buffer 能处理最后一块
        if not buffer:find('\r?\n\r?\n$', 1) then
          buffer = buffer .. '\n\n'
        end
        process_buffer()
      end
      -- OpenAI SSE 流末尾的 [DONE] 标记
      table.insert(pending, 'data: [DONE]\n\n')
      local ok_flush = flush_pending()
      if not ok_flush then
        return nil, 'failed to flush final anthropic stream'
      end
      return true
    end
    buffer = buffer .. chunk
    process_buffer()
    local ok_flush = flush_pending()
    if not ok_flush then
      return nil, 'failed to flush anthropic stream chunk'
    end
  end
end

-- opts.skip_current_provider: 为 true 时不尝试当前 provider 的其他 key，直接切换 provider
local function pick_retry_target(cfg, std_model, endpoint_key, current_provider, current_model, attempted_keys_by_provider, exhausted_providers, opts)
  opts = opts or {}
  local skip_current = not not opts.skip_current_provider

  if not skip_current then
    local current_attempts = attempted_keys_by_provider[current_provider.name] or {}
    local retry_key = keypool.pick_key(current_provider, { exclude_key_ids = current_attempts })
    if retry_key then
      return current_provider, current_model, retry_key
    end
  end

  exhausted_providers[current_provider.name] = true

  local switches = 0
  while switches < 16 do
    switches = switches + 1
    local alt_provider, alt_model, alt_key = router.select_provider_with_key(cfg, std_model, {
      exclude_providers = exhausted_providers,
      exclude_key_ids_by_provider = attempted_keys_by_provider,
    })
    if not alt_provider then
      return nil, nil, nil
    end
    local endpoint = alt_provider.endpoints and alt_provider.endpoints[endpoint_key] or nil
    if endpoint then
      if alt_key then
        return alt_provider, alt_model, alt_key
      end
    end
    exhausted_providers[alt_provider.name] = true
  end

  return nil, nil, nil
end

function _M.handle(endpoint_key)
  observe.start_request()

  -- 鉴权检查
  local auth_ok, auth_err = auth.validate()
  if not auth_ok then
    ngx.ctx.error_type = 'auth_failed'
    ngx.log(ngx.WARN, '[openai_compat] authentication failed: ', auth_err or 'unknown')
    return errors.send(401, auth_err or 'authentication failed', 'authentication_error')
  end

  local cfg = runtime.get_config()
  if not cfg then
    ngx.ctx.error_type = 'config_error'
    return errors.unavailable('config not loaded')
  end

  local raw_body = read_body()
  if not raw_body or raw_body == '' then
    ngx.ctx.error_type = 'invalid_request'
    return errors.bad_request('missing request body')
  end

  local body, decode_err = cjson.decode(raw_body)
  if not body then
    ngx.ctx.error_type = 'invalid_request'
    return errors.bad_request('invalid json body: ' .. tostring(decode_err))
  end

  local input_model = body.model
  if not input_model or input_model == '' then
    ngx.ctx.error_type = 'invalid_request'
    return errors.bad_request('missing model')
  end

  local requested_provider = nil
  if type(body.provider) == 'string' and body.provider ~= '' then
    requested_provider = body.provider
  end
  body.provider = nil

  local std_model = normalize.to_standard(cfg, input_model)
  if not std_model then
    ngx.ctx.error_type = 'invalid_model'
    return errors.bad_request('unsupported model: ' .. tostring(input_model))
  end

  ngx.ctx.input_model = input_model
  ngx.ctx.std_model = std_model

  local select_opts = {}
  if requested_provider then
    select_opts.prefer_provider = requested_provider
  end

  local provider, provider_model, key, select_err = router.select_provider_with_key(cfg, std_model, select_opts)
  if not provider then
    ngx.ctx.error_type = 'no_provider'
    if select_err == 'no_provider_available' then
      return errors.unavailable('no provider available')
    end
    return errors.unavailable('provider selection failed')
  end

  local endpoint = provider.endpoints and provider.endpoints[endpoint_key] or nil
  if not endpoint then
    ngx.ctx.error_type = 'config_error'
    return errors.unavailable('provider endpoint not configured')
  end

  local stream_body = deep_copy(body)
  apply_provider_request_defaults(stream_body, provider)
  stream_body.model = provider_model
  local body_json, encode_err = encode_body_for_provider(stream_body, provider)
  if not body_json then
    ngx.ctx.error_type = 'invalid_request'
    return errors.bad_request('failed to encode body: ' .. tostring(encode_err))
  end

  local is_stream = body.stream == true
  ngx.ctx.stream = is_stream

  if is_stream then
    local start_time = ngx.now()
    local stream_res, req_err = nil, nil
    local final_provider = provider
    local final_key = key
    local final_model = provider_model
    local final_endpoint = endpoint
    local attempted_keys_by_provider = {}
    local exhausted_providers = {}
    local max_attempts = 16
    local attempt = 0
    local last_res = nil

    while attempt < max_attempts do
      attempt = attempt + 1
      final_provider = provider
      final_key = key
      final_model = provider_model
      final_endpoint = provider.endpoints and provider.endpoints[endpoint_key] or nil

      if not final_endpoint then
        ngx.ctx.error_type = 'config_error'
        return errors.unavailable('provider endpoint not configured')
      end

      attempted_keys_by_provider[provider.name] = attempted_keys_by_provider[provider.name] or {}
      attempted_keys_by_provider[provider.name][key.id] = true

      local attempt_body = deep_copy(body)
      apply_provider_request_defaults(attempt_body, provider)
      attempt_body.model = provider_model
      -- Gemini: 从缓存回注 thought_signature，防止 400 missing thought_signature
      if gemini_sig.is_gemini_provider(provider) then
        gemini_sig.inject_into_body(attempt_body)
      end
      local encoded, body_err = encode_body_for_provider(attempt_body, provider)
      if not encoded then
        ngx.ctx.error_type = 'invalid_request'
        return errors.bad_request('failed to encode body: ' .. tostring(body_err))
      end
      body_json = encoded

      local url = join_url(provider.base_url, final_endpoint)
      local request_headers = build_headers(provider, key, ngx.ctx.request_id)
      log_upstream_request(provider, url, request_headers, body_json)

      if attempt == 1 then
        ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] making stream request: provider=', provider.name, ', url=', url, ', model=', provider_model, ', key_id=', key.id, ', ssl_verify=', provider.ssl_verify)
      else
        ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] retrying stream with provider=', provider.name, ', url=', url, ', key_id=', key.id, ', attempt=', attempt)
      end

      stream_res, req_err = http_client.request_stream({
        url = url,
        method = 'POST',
        headers = request_headers,
        body = body_json,
        timeout_ms = provider.timeout_ms,
        ssl_verify = provider.ssl_verify,
        proxy_url = provider.proxy_url,
      })

      if not stream_res and req_err then
        log_failed_request(provider, url, request_headers, body_json, nil, req_err)
        last_res = nil
      elseif stream_res and stream_res.status ~= 200 then
        local err_body, read_err = stream_res.read_all(256 * 1024)
        if read_err and read_err ~= 'body exceeds limit' then
          ngx.log(ngx.WARN, '[', format_timestamp(), '] [openai_compat] failed reading stream error body: provider=', provider.name, ', status=', stream_res.status, ', error=', read_err)
        end
        stream_res.close()
        local res_obj = {
          status = stream_res.status,
          headers = stream_res.headers or {},
          body = err_body or '',
        }
        ngx.log(ngx.WARN, '[', format_timestamp(), '] [openai_compat] stream response non-200: provider=', provider.name, ', status=', res_obj.status, ', body_size=', #(res_obj.body or ''))
        log_failed_request(provider, url, request_headers, body_json, res_obj, nil)
        last_res = res_obj
      else
        ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] stream response ready: provider=', provider.name, ', status=200')
        break
      end

      if not should_retry(last_res, req_err) then
        break
      end

      local analysis = analyze_error_for_retry(last_res and last_res.status or nil, last_res, req_err)
      local cooldown_opts = {
        source = 'stream_retry',
        status = last_res and last_res.status or nil,
        limit_source = (extract_error_metadata(last_res) or {}).limit_source,
      }

      if analysis.cooldown_key then
        local ttl = analysis.key_cooldown_sec or runtime.key_cooldown_sec
        keypool.mark_key_cooldown(provider, key.id, ttl, cooldown_opts)
      elseif should_cooldown_key(last_res and last_res.status or nil, last_res, req_err) then
        -- 兼容老逻辑兜底（400 类错误模式匹配）
        keypool.mark_key_cooldown(provider, key.id, runtime.key_cooldown_sec, cooldown_opts)
      end

      if analysis.cooldown_provider_model then
        local ttl = analysis.pm_cooldown_sec or runtime.provider_model_cooldown_sec
        keypool.mark_provider_model_cooldown(provider.name, provider_model, ttl, cooldown_opts)
        ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] stream cooldown (provider,model)=', provider.name, '/', provider_model, ' for ', ttl, 's; reason=', is_connection_error(req_err) and 'connection_error' or 'shared_pool_rate_limit')
      end

      -- 退避（如果是在换 provider 而不是等 key，也可以小睡一下避免打爆下游）
      if attempt >= 2 then
        retry_backoff_sleep(attempt)
      end

      local next_provider, next_model, next_key = pick_retry_target(
        cfg,
        std_model,
        endpoint_key,
        provider,
        provider_model,
        attempted_keys_by_provider,
        exhausted_providers,
        { skip_current_provider = analysis.skip_same_provider }
      )
      if not next_provider then
        break
      end

      provider = next_provider
      provider_model = next_model
      key = next_key
    end

    ngx.ctx.latency_ms = math.floor((ngx.now() - start_time) * 1000)
    ngx.ctx.provider = final_provider.name
    ngx.ctx.provider_model = final_model
    ngx.ctx.key_id = final_key.id

    if not stream_res then
      if not last_res then
        local error_details = {
          provider = final_provider.name,
          url = join_url(final_provider.base_url, final_endpoint or endpoint),
          key_id = final_key.id,
          error = req_err or 'unknown error',
          ssl_verify = final_provider.ssl_verify,
          timeout_ms = final_provider.timeout_ms,
        }
        ngx.log(ngx.ERR, '[', format_timestamp(), '] [openai_compat] stream upstream request failed: ', cjson.encode(error_details))
        ngx.ctx.error_type = 'upstream_error'
        ngx.ctx.error_details = error_details
        return errors.send(502, 'upstream request failed', 'upstream_error')
      end
      ngx.ctx.upstream_status = last_res.status
      ngx.ctx.error_type = classify_error(last_res.status, req_err)
      copy_response_headers(last_res.headers)
      observe.maybe_expose_selection(final_provider, final_key)
      ngx.status = last_res.status
      if anthropic.is_anthropic(final_provider) then
        ngx.say(anthropic.translate_error_response(last_res.body or ''))
      else
        ngx.say(inject_channel_to_json_response(last_res.body or '', final_provider.name))
      end
      return ngx.exit(last_res.status)
    end

    ngx.ctx.upstream_status = 200
    ngx.ctx.error_type = nil
    copy_response_headers(stream_res.headers)
    ngx.header['X-Accel-Buffering'] = 'no'
    -- 对客户端保持 OpenAI SSE 格式：text/event-stream
    ngx.header['Content-Type'] = 'text/event-stream'
    observe.maybe_expose_selection(final_provider, final_key)
    ngx.status = 200
    local relay_ok, relay_err
    if anthropic.is_anthropic(final_provider) then
      relay_ok, relay_err = relay_anthropic_stream(stream_res, final_model, ngx.ctx.request_id)
    else
      relay_ok, relay_err = relay_stream_response(stream_res, final_provider)
    end
    stream_res.close()
    if not relay_ok then
      ngx.log(ngx.ERR, '[', format_timestamp(), '] [openai_compat] stream relay failed: provider=', final_provider.name, ', key_id=', final_key.id, ', error=', relay_err)

      -- 中继阶段出错：虽然已向客户端发送 200（无法再改状态码），
      -- 但必须正确标记错误分类并触发 cooldown，避免后续请求继续撞同一个有问题的上游
      ngx.ctx.error_type = classify_error(nil, relay_err)

      local analysis = analyze_error_for_retry(nil, nil, relay_err)
      local cooldown_opts = {
        source = 'stream_relay_failed',
        status = nil,
        limit_source = nil,
      }

      if analysis.cooldown_key then
        local ttl = analysis.key_cooldown_sec or runtime.key_cooldown_sec
        keypool.mark_key_cooldown(final_provider, final_key.id, ttl, cooldown_opts)
      end

      if analysis.cooldown_provider_model then
        local ttl = analysis.pm_cooldown_sec or runtime.provider_model_cooldown_sec
        keypool.mark_provider_model_cooldown(final_provider.name, final_model, ttl, cooldown_opts)
        ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] stream relay cooldown (provider,model)=', final_provider.name, '/', final_model, ' for ', ttl, 's; reason=', is_connection_error(relay_err) and 'connection_error' or 'relay_error')
      end
    end
    return ngx.exit(200)
  end

  local start_time = ngx.now()
  local res, req_err = nil, nil
  local final_provider = provider
  local final_key = key
  local final_model = provider_model
  local final_endpoint = endpoint
  local attempted_keys_by_provider = {}
  local exhausted_providers = {}
  local max_attempts = 16
  local attempt = 0

  while attempt < max_attempts do
    attempt = attempt + 1
    final_provider = provider
    final_key = key
    final_model = provider_model
    final_endpoint = provider.endpoints and provider.endpoints[endpoint_key] or nil

    if not final_endpoint then
      ngx.ctx.error_type = 'config_error'
      return errors.unavailable('provider endpoint not configured')
    end

    attempted_keys_by_provider[provider.name] = attempted_keys_by_provider[provider.name] or {}
    attempted_keys_by_provider[provider.name][key.id] = true

    local attempt_body = deep_copy(body)
    apply_provider_request_defaults(attempt_body, provider)
    attempt_body.model = provider_model
    -- Gemini: 从缓存回注 thought_signature，防止 400 missing thought_signature
    if gemini_sig.is_gemini_provider(provider) then
      gemini_sig.inject_into_body(attempt_body)
    end
    local encoded, body_err = encode_body_for_provider(attempt_body, provider)
    if not encoded then
      ngx.ctx.error_type = 'invalid_request'
      return errors.bad_request('failed to encode body: ' .. tostring(body_err))
    end
    body_json = encoded

    local url = join_url(provider.base_url, final_endpoint)
    local request_headers = build_headers(provider, key, ngx.ctx.request_id)

    if attempt == 1 then
      ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] making request: provider=', provider.name, ', url=', url, ', model=', provider_model, ', key_id=', key.id, ', ssl_verify=', provider.ssl_verify)
    else
      ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] retrying with provider=', provider.name, ', url=', url, ', key_id=', key.id, ', attempt=', attempt)
    end
    log_upstream_request(provider, url, request_headers, body_json)
    res, req_err = do_request(provider, key, final_endpoint, body_json, ngx.ctx.request_id)

    if not res and req_err then
      log_failed_request(provider, url, request_headers, body_json, nil, req_err)
    elseif res and res.status ~= 200 then
      log_failed_request(provider, url, request_headers, body_json, res, nil)
    elseif res then
      ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] request response: provider=', provider.name, ', status=', res.status, ', body_size=', #(res.body or ''))
    end

    if not should_retry(res, req_err) then
      break
    end

    local analysis = analyze_error_for_retry(res and res.status or nil, res, req_err)
    local cooldown_opts = {
      source = 'non_stream_retry',
      status = res and res.status or nil,
      limit_source = (extract_error_metadata(res) or {}).limit_source,
    }

    if analysis.cooldown_key then
      local ttl = analysis.key_cooldown_sec or runtime.key_cooldown_sec
      keypool.mark_key_cooldown(provider, key.id, ttl, cooldown_opts)
    elseif should_cooldown_key(res and res.status or nil, res, req_err) then
      -- 兼容老逻辑兜底（400 类错误模式匹配）
      keypool.mark_key_cooldown(provider, key.id, runtime.key_cooldown_sec, cooldown_opts)
    end

    if analysis.cooldown_provider_model then
      local ttl = analysis.pm_cooldown_sec or runtime.provider_model_cooldown_sec
      keypool.mark_provider_model_cooldown(provider.name, provider_model, ttl, cooldown_opts)
      ngx.log(ngx.INFO, '[', format_timestamp(), '] [openai_compat] non-stream cooldown (provider,model)=', provider.name, '/', provider_model, ' for ', ttl, 's; reason=', is_connection_error(req_err) and 'connection_error' or 'shared_pool_rate_limit')
    end

    -- 指数退避
    if attempt >= 2 then
      retry_backoff_sleep(attempt)
    end

    local next_provider, next_model, next_key = pick_retry_target(
      cfg,
      std_model,
      endpoint_key,
      provider,
      provider_model,
      attempted_keys_by_provider,
      exhausted_providers,
      { skip_current_provider = analysis.skip_same_provider }
    )
    if not next_provider then
      break
    end

    provider = next_provider
    provider_model = next_model
    key = next_key
  end

  ngx.ctx.latency_ms = math.floor((ngx.now() - start_time) * 1000)
  ngx.ctx.provider = final_provider.name
  ngx.ctx.provider_model = final_model
  ngx.ctx.key_id = final_key.id

  if not res then
    local error_details = {
      provider = final_provider.name,
      url = join_url(final_provider.base_url, final_endpoint or endpoint),
      key_id = final_key.id,
      error = req_err or 'unknown error',
      ssl_verify = final_provider.ssl_verify,
      timeout_ms = final_provider.timeout_ms,
    }
    ngx.log(ngx.ERR, '[', format_timestamp(), '] [openai_compat] upstream request failed: ', cjson.encode(error_details))
    ngx.ctx.error_type = 'upstream_error'
    ngx.ctx.error_details = error_details
    return errors.send(502, 'upstream request failed', 'upstream_error')
  end

  ngx.ctx.upstream_status = res.status
  ngx.ctx.error_type = classify_error(res.status, req_err)

  copy_response_headers(res.headers)
  observe.maybe_expose_selection(final_provider, final_key)

  ngx.status = res.status
  if anthropic.is_anthropic(final_provider) then
    if res.status == 200 then
      ngx.say(anthropic.translate_response(res.body or '', final_model, final_provider.name))
    else
      ngx.say(anthropic.translate_error_response(res.body or ''))
    end
  else
    -- Gemini: 非流式 200 响应中捕获 thought_signature，供后续请求回注
    if res.status == 200 and gemini_sig.is_gemini_provider(final_provider) then
      gemini_sig.capture_from_response(res.body)
    end
    ngx.say(inject_channel_to_json_response(res.body or '', final_provider.name))
  end
  return ngx.exit(res.status)
end

return _M
