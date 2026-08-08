local _M = {}

-- 多级超时默认值（毫秒）
-- connect: TCP 连接 + 代理 CONNECT + TLS 握手，5s 足以判定代理存活
-- send:    发送请求 body，30s 覆盖大 prompt
-- read:    读响应，5min 覆盖长流式输出（SSE 两次数据间隔超时，非总时长）
local DEFAULT_CONNECT_TIMEOUT_MS = 5000
local DEFAULT_SEND_TIMEOUT_MS = 30000
local DEFAULT_READ_TIMEOUT_MS = 300000

-- 代理专用超时：经 HTTP 代理时 CONNECT 隧道 + TLS 握手 + 远端首字节都需要额外时间
-- TLS 握手经代理（MITM 证书拦截）可能极慢（偶见 >30s），给 45s 留余量
local DEFAULT_PROXY_CONNECT_TIMEOUT_MS = 120000  -- 代理 CONNECT + TLS
local DEFAULT_PROXY_READ_TIMEOUT_MS = 600000    -- 代理链路首字节延迟更高，给 10min

-- 连接池默认值
local DEFAULT_POOL_IDLE_MS = 60000   -- 空闲 60s 后自动关闭
local DEFAULT_POOL_SIZE = 100         -- 每个 pool 最多保留 100 条连接

local function format_timestamp()
  local now = ngx.now()
  local sec = math.floor(now)
  local msec = math.floor((now - sec) * 1000)
  return os.date('%Y-%m-%d %H:%M:%S', sec) .. string.format('.%03d', msec)
end

local function parse_url(url)
  local scheme, rest = url:match('^(https?)://(.+)$')
  if not scheme then
    return nil, 'invalid url: ' .. tostring(url)
  end

  local host_port, path = rest:match('^([^/]+)(/.*)$')
  if not host_port then
    host_port = rest
    path = '/'
  end

  local host, port = host_port:match('^([^:]+):(%d+)$')
  local port_num = tonumber(port) or (scheme == 'https' and 443 or 80)
  local host_only = host or host_port
  local host_header = host_only

  if port and ((scheme == 'https' and port_num ~= 443) or (scheme == 'http' and port_num ~= 80)) then
    host_header = host_only .. ':' .. port
  end

  return {
    scheme = scheme,
    host = host_only,
    port = port_num,
    path = path,
    host_header = host_header,
  }
end

local function read_chunked(sock)
  local chunks = {}
  while true do
    local line, err = sock:receive('*l')
    if not line then
      return nil, err
    end
    local size = tonumber(line:match('^[0-9a-fA-F]+'), 16)
    if not size then
      return nil, 'invalid chunk size'
    end
    if size == 0 then
      local trailer = sock:receive('*l')
      if not trailer then
        return nil, 'invalid chunk trailer'
      end
      while true do
        local extra = sock:receive('*l')
        if not extra or extra == '' then
          break
        end
      end
      break
    end

    local data, err = sock:receive(size)
    if not data then
      return nil, err
    end
    table.insert(chunks, data)
    local crlf, err = sock:receive(2)
    if not crlf then
      return nil, err
    end
  end

  return table.concat(chunks)
end

local function read_status_and_headers(sock)
  local status_line, status_err = sock:receive('*l')
  if not status_line then
    return nil, nil, nil, nil, status_err
  end

  local http_version, status, reason = status_line:match('^(HTTP/%d+%.%d+)%s+(%d+)%s*(.*)$')
  if not status then
    return nil, nil, nil, nil, 'invalid status line'
  end

  local resp_headers = {}
  while true do
    local line, header_err = sock:receive('*l')
    if not line then
      return nil, nil, nil, nil, header_err
    end
    if line == '' then
      break
    end
    local name, value = line:match('^([^:]+):%s*(.*)$')
    if name then
      local key = name:lower()
      if resp_headers[key] then
        resp_headers[key] = resp_headers[key] .. ', ' .. value
      else
        resp_headers[key] = value
      end
    end
  end

  return tonumber(status), reason, http_version, resp_headers, nil
end

-- 设置多级超时：connect / send / read 独立
-- 优先使用 opts 中的分级超时，其次回退到 opts.timeout_ms（兼容老配置），最后用默认值
-- 当使用 HTTP 代理时，connect 和 read 使用更宽松的代理专用默认值
local function apply_timeouts(sock, opts)
  local has_proxy = type(opts.proxy_url) == 'string' and opts.proxy_url ~= ''
  local default_connect = has_proxy and DEFAULT_PROXY_CONNECT_TIMEOUT_MS or DEFAULT_CONNECT_TIMEOUT_MS
  local default_read = has_proxy and DEFAULT_PROXY_READ_TIMEOUT_MS or DEFAULT_READ_TIMEOUT_MS

  local connect_ms = opts.connect_timeout_ms or default_connect
  local send_ms = opts.send_timeout_ms or DEFAULT_SEND_TIMEOUT_MS
  local read_ms = opts.read_timeout_ms or default_read

  -- 兼容老配置：如果只传了 timeout_ms
  -- - connect/send：取较小值（这两个阶段不应超过默认上限）
  -- - read：只允许放大不允许缩小！LLM 流式 SSE chunk 间隔（尤其 reasoning 模型）可能 >1min，
  --   不能因为 provider.timeout_ms=60s 就把默认 read idle 拉低到 60s，否则频繁误杀
  if opts.timeout_ms then
    if not opts.connect_timeout_ms then
      connect_ms = math.min(default_connect, opts.timeout_ms)
    end
    if not opts.send_timeout_ms then
      send_ms = math.min(DEFAULT_SEND_TIMEOUT_MS, opts.timeout_ms)
    end
    if not opts.read_timeout_ms then
      read_ms = math.max(default_read, opts.timeout_ms)
    end
  end

  local ok = pcall(function()
    sock:settimeouts(connect_ms, send_ms, read_ms)
  end)
  if not ok then
    -- 旧版 OpenResty 不支持 settimeouts，回退到 settimeout（用 read 时长兜底）
    sock:settimeout(read_ms)
  end
end

-- 构建连接池名称：区分直连 / 代理+目标，避免 HTTPS 隧道错用
local function build_pool_name(parsed, proxy)
  if proxy and parsed.scheme == 'https' then
    -- HTTPS 经代理：池名必须包含 target，否则 A 的隧道会给 B 用
    return 'proxy-tls:' .. proxy.host .. ':' .. proxy.port .. ':' .. parsed.host .. ':' .. parsed.port
  elseif proxy and parsed.scheme == 'http' then
    return 'proxy-http:' .. proxy.host .. ':' .. proxy.port
  else
    return 'direct:' .. parsed.host .. ':' .. parsed.port
  end
end

-- 判断响应是否允许连接复用（根据响应头）
local function can_pool_response(http_version, resp_headers)
  local conn = resp_headers and resp_headers['connection']
  if conn and conn:lower():find('close', 1, true) then
    return false
  end
  if http_version == 'HTTP/1.0' then
    if not (conn and conn:lower():find('keep-alive', 1, true)) then
      return false
    end
  end
  return true
end

-- 智能关闭：干净结束时放回池子，否则直接关闭
local function smart_close(sock, clean_end, can_pool)
  if clean_end and can_pool then
    local ok, err = sock:setkeepalive(DEFAULT_POOL_IDLE_MS, DEFAULT_POOL_SIZE)
    if ok then
      return true
    end
    ngx.log(ngx.WARN, '[', format_timestamp(), '] [http_client] setkeepalive failed: ', tostring(err), ', closing instead')
  end
  return sock:close()
end

local function open_socket_and_send(opts)
  if not opts or not opts.url then
    return nil, nil, 'missing url'
  end

  local parsed, err = parse_url(opts.url)
  if not parsed then
    return nil, nil, err
  end

  -- 解析 HTTP 代理（可选）：opts.proxy_url 形如 http://host:port
  local proxy = nil
  if type(opts.proxy_url) == 'string' and opts.proxy_url ~= '' then
    proxy, err = parse_url(opts.proxy_url)
    if not proxy then
      return nil, nil, 'invalid proxy_url: ' .. tostring(opts.proxy_url)
    end
    if proxy.scheme ~= 'http' then
      return nil, nil, 'only http proxy scheme is supported, got: ' .. tostring(proxy.scheme)
    end
  end

  local sock = ngx.socket.tcp()
  apply_timeouts(sock, opts)

  -- 通过代理连接时，TCP 连接到代理而非目标；否则直连目标
  local connect_host = proxy and proxy.host or parsed.host
  local connect_port = proxy and proxy.port or parsed.port

  -- 使用目标感知的连接池名称，复用已建立的 TCP+TLS 连接
  local pool_name = build_pool_name(parsed, proxy)
  local ok, conn_err = sock:connect(connect_host, connect_port, { pool = pool_name })
  if not ok then
    ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] connection failed: url=', opts.url, ', host=', connect_host, ', port=', connect_port, ', proxy=', proxy and opts.proxy_url or 'none', ', error=', conn_err)
    return nil, nil, conn_err
  end

  -- 检查是否是池中复用的连接：reused > 0 表示已建立过 CONNECT 隧道和 TLS 握手
  local reused_times = sock:getreusedtimes() or 0

  if reused_times == 0 then
    -- 全新连接：需要建立 CONNECT 隧道（HTTPS 经代理）和 TLS 握手
    -- HTTPS 目标经 HTTP 代理：先发 CONNECT 建立隧道，再做 TLS 握手
    if proxy and parsed.scheme == 'https' then
      local connect_target = parsed.host .. ':' .. parsed.port
      local connect_req = 'CONNECT ' .. connect_target .. ' HTTP/1.1\r\n' ..
                          'Host: ' .. connect_target .. '\r\n' ..
                          'Proxy-Connection: keep-alive\r\n\r\n'
      local sent, send_err = sock:send(connect_req)
      if not sent then
        ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] proxy CONNECT send failed: url=', opts.url, ', proxy=', opts.proxy_url, ', error=', send_err)
        sock:close()
        return nil, nil, 'proxy CONNECT send failed: ' .. tostring(send_err)
      end

      local status_line, sl_err = sock:receive('*l')
      if not status_line then
        ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] proxy CONNECT no response: url=', opts.url, ', proxy=', opts.proxy_url, ', error=', sl_err)
        sock:close()
        return nil, nil, 'proxy CONNECT failed: ' .. tostring(sl_err)
      end

      local _, proxy_status_str = status_line:match('^(HTTP/%d+%.%d+)%s+(%d+)')
      local proxy_status = tonumber(proxy_status_str)

      -- 读取并丢弃 CONNECT 响应剩余的头部
      while true do
        local line, h_err = sock:receive('*l')
        if not line or line == '' then
          break
        end
      end

      if not proxy_status or proxy_status < 200 or proxy_status >= 300 then
        ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] proxy CONNECT rejected: url=', opts.url, ', proxy=', opts.proxy_url, ', status=', status_line)
        sock:close()
        return nil, nil, 'proxy CONNECT rejected: ' .. tostring(status_line)
      end

      ngx.log(ngx.INFO, '[', format_timestamp(), '] [http_client] proxy CONNECT established: url=', opts.url, ', proxy=', opts.proxy_url)
    end

    if parsed.scheme == 'https' then
      local ssl_verify = opts.ssl_verify ~= false
      local ssl_ok, ssl_err = sock:sslhandshake(nil, parsed.host, ssl_verify)
      if not ssl_ok then
        ngx.log(ngx.WARN, '[', format_timestamp(), '] [http_client] SSL handshake failed: url=', opts.url, ', host=', parsed.host, ', ssl_verify=', ssl_verify, ', error=', ssl_err)
        sock:close()
        return nil, nil, ssl_err
      end
    end
  else
    ngx.log(ngx.INFO, '[', format_timestamp(), '] [http_client] reusing pooled connection: url=', opts.url, ', reused_times=', reused_times)
  end

  local method = opts.method or 'GET'
  local headers = opts.headers or {}
  headers['Host'] = headers['Host'] or parsed.host_header
  headers['Connection'] = headers['Connection'] or 'keep-alive'

  if opts.body and not headers['Content-Length'] then
    headers['Content-Length'] = #opts.body
  end

  -- HTTP 目标经 HTTP 代理（未走 CONNECT）：请求行使用绝对 URI；其余情况使用相对路径
  local request_target = parsed.path
  if proxy and parsed.scheme == 'http' then
    request_target = opts.url
  end

  local lines = { method .. ' ' .. request_target .. ' HTTP/1.1' }
  for name, value in pairs(headers) do
    table.insert(lines, name .. ': ' .. tostring(value))
  end
  table.insert(lines, '')
  table.insert(lines, '')

  local request = table.concat(lines, '\r\n')
  local bytes, send_err = sock:send(request)
  if not bytes then
    ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] send request failed: url=', opts.url, ', error=', send_err)
    sock:close()
    return nil, nil, send_err
  end

  if opts.body then
    local ok_body, body_err = sock:send(opts.body)
    if not ok_body then
      ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] send body failed: url=', opts.url, ', body_size=', #opts.body, ', error=', body_err)
      sock:close()
      return nil, nil, body_err
    end
  end

  return sock, parsed, nil
end

function _M.request_stream(opts)
  local sock, _, err = open_socket_and_send(opts)
  if not sock then
    return nil, err
  end

  ngx.log(ngx.INFO, '[', format_timestamp(), '] [http_client] waiting for stream response: url=', opts.url)
  local status_num, reason, http_version, resp_headers, status_err = read_status_and_headers(sock)
  if not status_num then
    ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] receive stream status failed: url=', opts.url, ', error=', status_err, ', timeout_ms=', opts.timeout_ms)
    sock:close()
    return nil, status_err
  end

  local method = opts.method or 'GET'
  local no_body = method == 'HEAD' or status_num == 204 or status_num == 304
  local transfer = resp_headers['transfer-encoding']
  local mode = 'until_eof'
  local fixed_remaining = nil
  local chunk_remaining = 0
  local chunk_done = false

  -- 连接复用状态：流式响应干净结束后才放回池子
  local can_pool = can_pool_response(http_version, resp_headers)
  local stream_clean_end = false  -- read_chunk 在无错误返回 nil 时置 true

  if no_body then
    mode = 'none'
    stream_clean_end = true
  elseif transfer and transfer:lower():find('chunked', 1, true) then
    mode = 'chunked'
  else
    local length = tonumber(resp_headers['content-length'] or '')
    if length then
      mode = 'fixed'
      fixed_remaining = length
    end
  end

  local function read_chunk()
    if mode == 'none' then
      stream_clean_end = true
      return nil
    end

    if mode == 'fixed' then
      if fixed_remaining <= 0 then
        stream_clean_end = true
        return nil
      end
      local to_read = math.min(fixed_remaining, 8192)
      local data, read_err, partial = sock:receive(to_read)
      local out = data or partial
      if not out or #out == 0 then
        if read_err == 'closed' and fixed_remaining <= 0 then
          stream_clean_end = true
          return nil
        end
        return nil, read_err or 'read fixed body failed'
      end
      fixed_remaining = fixed_remaining - #out
      if fixed_remaining <= 0 then
        stream_clean_end = true
      end
      return out
    end

    if mode == 'chunked' then
      if chunk_done then
        stream_clean_end = true
        return nil
      end

      if chunk_remaining == 0 then
        local line, line_err = sock:receive('*l')
        if not line then
          return nil, line_err or 'read chunk size failed'
        end
        local size = tonumber(line:match('^[0-9a-fA-F]+'), 16)
        if not size then
          return nil, 'invalid chunk size'
        end
        if size == 0 then
          local trailer, trailer_err = sock:receive('*l')
          if not trailer and trailer_err then
            return nil, trailer_err
          end
          while true do
            local extra, extra_err = sock:receive('*l')
            if not extra then
              if extra_err == 'closed' then
                break
              end
              return nil, extra_err
            end
            if extra == '' then
              break
            end
          end
          chunk_done = true
          stream_clean_end = true
          return nil
        end
        chunk_remaining = size
      end

      local to_read = math.min(chunk_remaining, 8192)
      local data, read_err, partial = sock:receive(to_read)
      local out = data or partial
      if not out or #out == 0 then
        return nil, read_err or 'read chunk data failed'
      end
      chunk_remaining = chunk_remaining - #out
      if chunk_remaining == 0 then
        local _, crlf_err = sock:receive(2)
        if crlf_err then
          return nil, crlf_err
        end
      end
      return out
    end

    local data, read_err, partial = sock:receive(8192)
    local out = data or partial
    if out and #out > 0 then
      return out
    end
    if read_err == 'closed' then
      stream_clean_end = true
      return nil
    end
    return nil, read_err or 'read body failed'
  end

  local function read_all(max_bytes)
    local parts = {}
    local total = 0
    while true do
      local chunk, chunk_err = read_chunk()
      if chunk_err then
        return nil, chunk_err
      end
      if not chunk then
        break
      end
      total = total + #chunk
      if max_bytes and total > max_bytes then
        table.insert(parts, chunk:sub(1, max_bytes - (total - #chunk)))
        return table.concat(parts), 'body exceeds limit'
      end
      table.insert(parts, chunk)
    end
    return table.concat(parts), nil
  end

  local function close()
    return smart_close(sock, stream_clean_end, can_pool)
  end

  return {
    status = status_num,
    reason = reason,
    http_version = http_version,
    headers = resp_headers,
    read_chunk = read_chunk,
    read_all = read_all,
    close = close,
  }
end

function _M.request(opts)
  local sock, _, err = open_socket_and_send(opts)
  if not sock then
    return nil, err
  end

  ngx.log(ngx.INFO, '[', format_timestamp(), '] [http_client] waiting for response: url=', opts.url)
  local status_num, reason, http_version, resp_headers, status_err = read_status_and_headers(sock)
  if not status_num then
    ngx.log(ngx.ERR, '[', format_timestamp(), '] [http_client] receive status failed: url=', opts.url, ', error=', status_err, ', timeout_ms=', opts.timeout_ms)
    sock:close()
    return nil, status_err
  end

  local body = ''
  local clean_end = true  -- 非流式：只要完整读完 body 就算干净结束
  local can_pool = can_pool_response(http_version, resp_headers)
  local method = opts.method or 'GET'
  if method ~= 'HEAD' and status_num ~= 204 and status_num ~= 304 then
    local transfer = resp_headers['transfer-encoding']
    if transfer and transfer:lower():find('chunked', 1, true) then
      local chunked, chunk_err = read_chunked(sock)
      if not chunked then
        clean_end = false
        sock:close()
        return nil, chunk_err
      end
      body = chunked
    else
      local length = tonumber(resp_headers['content-length'] or '')
      if length then
        local data, body_err = sock:receive(length)
        if not data then
          clean_end = false
          sock:close()
          return nil, body_err
        end
        body = data
      else
        local data, body_err = sock:receive('*a')
        if not data then
          clean_end = false
          sock:close()
          return nil, body_err
        end
        body = data
      end
    end
  end

  smart_close(sock, clean_end, can_pool)

  return {
    status = status_num,
    reason = reason,
    http_version = http_version,
    headers = resp_headers,
    body = body,
  }
end

return _M
