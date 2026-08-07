local cjson = require('cjson.safe')
local stats = require('core.stats')
local admin_auth = require('core.admin_auth')

ngx.ctx.skip_stats = true

if not admin_auth.guard() then
  return
end

local args = ngx.req.get_uri_args()
local window_minutes = tonumber(args.window or args.window_minutes) or 60
local interval_sec = tonumber(args.interval) or 3
if interval_sec < 1 then interval_sec = 1 end
if interval_sec > 30 then interval_sec = 30 end

ngx.header['Content-Type'] = 'text/event-stream; charset=utf-8'
ngx.header['Cache-Control'] = 'no-cache, no-store, private'
ngx.header['Connection'] = 'keep-alive'
ngx.header['X-Accel-Buffering'] = 'no'

ngx.send_headers()

local function send_sse(event, data)
  local payload = data
  if type(payload) ~= 'string' then
    payload = cjson.encode(payload) or ''
  end
  local lines = {}
  if event then
    lines[#lines + 1] = 'event: ' .. event
  end
  for line in payload:gmatch('[^\r\n]+') do
    lines[#lines + 1] = 'data: ' .. line
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ''
  local ok, err = ngx.print(table.concat(lines, '\n'))
  if not ok then
    return nil, err
  end
  ok, err = ngx.flush(true)
  if not ok then
    return nil, err
  end
  return true
end

local ok, err = send_sse('connected', {
  interval_sec = interval_sec,
  window_minutes = window_minutes,
  server_time = math.floor(ngx.now()),
})
if not ok then
  ngx.log(ngx.WARN, '[stats-sse] initial send failed: ', err)
  return
end

local max_iterations = math.floor(3600 / interval_sec)
local is_aborted_fn = ngx.is_aborted

for _ = 1, max_iterations do
  if type(is_aborted_fn) == 'function' then
    local aborted = is_aborted_fn()
    if aborted then
      ngx.log(ngx.INFO, '[stats-sse] client aborted connection')
      return
    end
  end

  ngx.sleep(interval_sec)

  local payload = stats.snapshot(window_minutes)
  local ok2, err2 = send_sse('snapshot', payload)
  if not ok2 then
    ngx.log(ngx.INFO, '[stats-sse] send failed (client gone?): ', err2)
    return
  end
end
