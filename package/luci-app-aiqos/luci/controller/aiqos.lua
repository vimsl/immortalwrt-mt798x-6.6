
--[[
/usr/lib/lua/luci/controller/aiqos.lua
LuCI controller: menu + routes + status API
V1.0.1: Added SINR value range validation
]]--

module("luci.controller.aiqos", package.seeall)

function index()
    entry({"admin", "services", "aiqos"},
          cbi("aiqos"),
          _("5G AI 信号优化"),
          50).dependent = false

    entry({"admin", "services", "aiqos", "status"},
          view("aiqos/status"),
          _("状态"),
          10)

    entry({"admin", "services", "aiqos", "status_json"},
          call("action_status_json"),
          nil).leaf = true

    entry({"admin", "services", "aiqos", "history_json"},
          call("action_history_json"),
          nil).leaf = true

    entry({"admin", "services", "aiqos", "lock_now"},
          call("action_lock_now"),
          nil).leaf = true
end

-- Validate SINR value: must be in realistic -50 to +50 dB range
local function sanitize_sinr(val)
    local n = tonumber(val)
    if not n then return nil end
    if n > -50 and n < 50 then
        return string.format("%.1f", n)
    end
    return nil
end

-- Validate SINR coefficient: must be 0.1 ~ 10.0
local function sanitize_coeff(val)
    local n = tonumber(val)
    if not n then return "1.0" end
    if n >= 0.1 and n <= 10.0 then
        return tostring(n)
    end
    return "1.0"
end

function action_status_json()
    luci.http.prepare_content("application/json")

    local status = {
        sinr = "N/A",
        rsrp = "N/A",
        bandwidth = "N/A",
        latency = "N/A",
        uptime = "N/A",
        cake_active = false,
        sinr_coeff = "1.0"
    }

    -- Read SINR from state file with validation
    local f = io.open("/tmp/aiqos_sinr_coeff", "r")
    if f then
        local line = f:read("*line")
        f:close()
        if line and #line > 0 then
            local parts = {}
            for word in line:gmatch("%S+") do
                table.insert(parts, word)
            end
            if #parts >= 2 then
                local coeff = sanitize_coeff(parts[1])
                local sinr = sanitize_sinr(parts[2])
                status.sinr_coeff = coeff
                if sinr then
                    status.sinr = sinr
                end
            elseif #parts == 1 then
                -- Single field: treat as raw value, validate
                local sinr = sanitize_sinr(parts[1])
                if sinr then
                    status.sinr = sinr
                end
            end
        end
    end

    -- Check CAKE qdisc
    local handle = io.popen("tc -s qdisc show dev wwan0 2>/dev/null | grep -A5 cake")
    if handle then
        local output = handle:read("*all")
        handle:close()
        if output and #output > 0 then
            status.cake_active = true
            local bw = output:match("bandwidth (%d+%a?)")
            if bw then
                status.bandwidth = bw
            end
        end
    end

    -- Read latency from cake-autorate log
    local handle3 = io.popen("tail -1 /var/log/cake-autorate.log 2>/dev/null | grep -oP 'OWD P99: \\K[0-9.]+'")
    if handle3 then
        local lat = handle3:read("*line")
        handle3:close()
        if lat then
            local n = tonumber(lat)
            if n and n > 0 and n < 10000 then
                status.latency = lat .. " ms"
            end
        end
    end

    -- Read aiqosd uptime
    local f2 = io.open("/var/run/aiqosd.pid", "r")
    if f2 then
        local pid = f2:read("*line")
        f2:close()
        if pid then
            local handle2 = io.popen("ps -p " .. pid .. " -o etime= 2>/dev/null")
            if handle2 then
                local etime = handle2:read("*line")
                handle2:close()
                if etime then
                    status.uptime = etime:match("^%s*(.-)%s*$")
                end
            end
        end
    end

    luci.http.write_json(status)
end

function action_history_json()
    luci.http.prepare_content("application/json")

    local history = {}
    local f = io.open("/var/log/sinr_injector.log", "r")
    if f then
        local lines = {}
        for line in f:lines() do
            local sinr = line:match("SINR=([%d.-]+)dB")
            if sinr then
                local n = tonumber(sinr)
                if n and n > -50 and n < 50 then
                    local ts = line:match("%[(.-)%]")
                    table.insert(lines, { time = ts, sinr = n })
                end
            end
        end
        f:close()

        local count = #lines
        if count > 100 then
            for i = count - 99, count do
                table.insert(history, lines[i])
            end
        else
            history = lines
        end
    end

    luci.http.write_json(history)
end

function action_lock_now()
    luci.http.prepare_content("application/json")

    local ret = os.execute("/usr/bin/night_lock.sh 2>&1")
    local result = {
        success = (ret == 0),
        message = ret == 0 and "Lock triggered successfully" or "Lock failed"
    }
    luci.http.write_json(result)
end
