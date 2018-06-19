local _M = {}

local cidr = require "libcidr-ffi"
local dyups = require "ngx.dyups"
local plutils = require "pl.utils"

local split = plutils.split

local function get_server_ips(server)
  local ips
  if server["_host_is_ip?"] then
    ips = { server["host"] }
  elseif server["_host_is_local_alias?"] then
    ips = { config["dns_resolver"]["_etc_hosts"][server["host"]] }
  else
    ips = ngx.shared.resolved_hosts:get(server["host"]) or ""
    ips = split(ips, ",", true)
  end

  return ips
end

local function generate_upstream_config(api)
  local upstream = ""

  local balance = api["balance_algorithm"]
  if balance == "least_conn" or balance == "least_conn" then
    upstream = upstream .. balance .. ";\n"
  end

  local keepalive = api["keepalive_connections"] or config["router"]["api_backends"]["keepalive_connections"]
  upstream = upstream .. "keepalive " .. keepalive .. ";\n"

  local servers = {}
  if api["servers"] then
    for _, server in ipairs(api["servers"]) do
      local ips = get_server_ips(server)
      if ips and server["port"] then
        for _, ip in ipairs(ips) do
          local nginx_ip
          local result = cidr.from_str(ip)
          if result and result.proto == 2 then
            nginx_ip = "[" .. ip .. "]"
          else
            nginx_ip = ip
          end

          -- Insert 5 copies of the server, and set max_fails=0. In combination
          -- with the global "proxy_next_upstream error" setting, this allows
          -- for the API backend requests to retry up to 5 times if a
          -- connection was never actually established.
          --
          -- This is a bit of a hack, but this helps deal with upstream
          -- keepalive connections that might get closed (either by the API
          -- backend or some other firewall or NAT in between).
          --
          -- max_fails=0 is important so that single servers don't get
          -- completely removed from rotation (for fail_timeout) if a single
          -- request fails. By repeating the same server IP multiple times,
          -- this also gives proxy_next_upstream a chance to failover and retry
          -- the same server.
          for i = 1, 5 do
            table.insert(servers, "server " .. nginx_ip .. ":" .. server["port"] .. " max_fails=0;")
          end
        end
      end
    end
  end

  if #servers == 0 then
    table.insert(servers, "server 127.255.255.255:80 down;")
  end

  upstream = upstream .. table.concat(servers, "\n") .. "\n"

  return upstream
end

local function update_upstream(backend_id, upstream_config)
  -- Apply the new backend with dyups. If dyups is locked, keep trying
  -- until we succeed or time out.
  local update_suceeded = false
  local wait_time = 0
  local sleep_time = 0.01
  local max_time = 5
  repeat
    local status = dyups.update(backend_id, upstream_config);
    if status == 200 then
      update_suceeded = true
    else
      ngx.sleep(sleep_time)
      wait_time = wait_time + sleep_time
    end
  until update_suceeded or wait_time > max_time

  if not update_suceeded then
    ngx.log(ngx.ERR, "Failed to setup upstream for " .. backend_id .. ". Trying to continue anyway...")
  end
end

function _M.setup_backends(apis)
  local upstreams_changed = false
  for _, api in ipairs(apis) do
    local backend_id = "api_umbrella_" .. api["_id"] .. "_backend"
    local upstream_config = generate_upstream_config(api)

    -- Only apply the upstream if it differs from the upstream currently
    -- installed. Since we're looping over all the APIs, this helps prevent
    -- unnecessary upstream changes.
    --
    -- Note that the current upstream tracking takes into account
    -- WORKER_GROUP_ID. This is to prevent race conditions with dyups when
    -- nginx is being reloaded. Since dyups needs to be setup after each reload
    -- (dyups itself doesn't persist), this prevents the dyups commands that
    -- might still be running in the old nginx workers (that are being spun
    -- down) from interfering with the new processes spinning up (and making
    -- them think the upstreams already setup).
    --
    -- TODO: balancer_by_lua is supposedly coming soon, which I think might
    -- offer a much cleaner way to deal with all this versus what we're
    -- currently doing with dyups. Revisit if that gets released.
    -- https://groups.google.com/d/msg/openresty-en/NS2dWt-xHsY/PYzi5fiiW8AJ
    local upstream_checksum = ngx.md5(upstream_config)
    local worker_group_backend_id = WORKER_GROUP_ID .. ":" .. backend_id
    local current_upstream_checksum = ngx.shared.upstream_checksums:get(worker_group_backend_id)
    if(upstream_checksum ~= current_upstream_checksum) then
      upstreams_changed = true
      update_upstream(backend_id, upstream_config)
      ngx.shared.upstream_checksums:set(worker_group_backend_id, upstream_checksum)
    end
  end

  -- After making changes to the upstreams with dyups, we have to wait for
  -- those changes to actually be read and applied to all the individual worker
  -- processes. So wait a bit more than what dyups_read_msg_timeout is
  -- configured to be.
  --
  -- We wait here so that we can better ensure that once setup_backends()
  -- finishes, then the updates should actually be in effect (which we use for
  -- knowing when config changes are in place in the /api-umbrella/v1/state
  -- API).
  if upstreams_changed then
    ngx.sleep(0.5)

    if config["app_env"] == "test" then
      ngx.update_time()
    end

    ngx.shared.active_config:set("upstreams_last_changed_at", ngx.now() * 1000)
  end

  ngx.shared.active_config:set("upstreams_setup_complete:" .. WORKER_GROUP_ID, true)
end

return _M
