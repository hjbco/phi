--
-- Created by IntelliJ IDEA.
-- User: yangyang.zhang
-- Date: 2018/2/24
-- Time: 15:13
-- 查询db和多级缓存
-- L1:Worker级别的LRU CACHE
-- L2:共享内存SHARED_DICT
-- L3:Redis,作为回源DB使用
--
local ngx_upstream = require "ngx.upstream"
local CONST = require "core.constants"
local mlcache = require "resty.mlcache"
local pretty_write = require("pl.pretty").write

local balancer_warpper = require "core.balancer.balancer_warpper"

local get_upstreams = ngx_upstream.get_upstreams
local set_peer_down = ngx_upstream.set_peer_down
local worker_pid = ngx.worker.pid

local ERR = ngx.ERR
local DEBUG = ngx.DEBUG
local NOTICE = ngx.NOTICE
local LOGGER = ngx.log

local EVENTS = CONST.EVENT_DEFINITION.UPSTREAM_EVENTS
local PHI_UPSTREAM_DICT_NAME = CONST.DICTS.PHI_UPSTREAM
local PHI_EVENTS_DICT_NAME = CONST.DICTS.PHI_EVENTS

local SHARED_DICT = ngx.shared[PHI_UPSTREAM_DICT_NAME]

local _M = {}
function _M:init()
    -- 加载配置文件中的upstream信息，所有的upstream信息使用stable占位
    local us = get_upstreams()
    for _, u in ipairs(us) do
        self.cache:set(u, nil, "stable")
    end
end

function _M:init_worker(observer)
    -- self.cache:update()
    self.observer = observer
    -- 关注dynamic upstream的更新操作
    observer.register(function(data, event, source, pid)
        LOGGER(DEBUG, "received event; source=", source,
            ", event=", event,
            ", data=", pretty_write(data),
            ", from process ", pid)
        if worker_pid() == pid then
            LOGGER(NOTICE, "do not process the event send from self")
        else
            -- server增删情况下，重建balancer
            self.cache:update()
        end
    end, EVENTS.DYNAMIC_UPS_SOURCE)
    -- 关注配置中的peer的启停
    observer.register(function(data, event, source, pid)
        LOGGER(DEBUG, "received event; source=", source,
            ", event=", event,
            ", data=", pretty_write(data),
            ", from process ", pid)
        if worker_pid() == pid and type(data[4]) ~= "boolean" then
            --            local _, _, upstreamInfo = self.cache:peek(data[1])
            --            if upstreamInfo then
            --                for k, v in pairs(upstreamInfo) do
            --                    if k == data[2] then
            --                        LOGGER(NOTICE, "update L2 cache,upstreamName:", data[1], ",server:", data[2])
            --                        local tmpJson = cjson.decode(v)
            --                        tmpJson.weight = data[3]
            --                        upstreamInfo[k] = cjson.encode(tmpJson)
            --                    end
            --                end
            --            end
            LOGGER(NOTICE, "do not process the event send from self")
        else
            if type(data[4]) == "boolean" then
                set_peer_down(data[1], data[2], data[3], data[4])
            else
                self:getUpstreamBalancer(data[1]).set(data[2], data[3])
            end
        end
    end, EVENTS.SOURCE)
end

-- 需要通知其他worker进程peer状态改变
function _M:peerStateChangeEvent(upstreamName, isBackup, peerId, down)
    local event = down and EVENTS.PEER_DOWN or EVENTS.PEER_UP
    self.observer.post(EVENTS.SOURCE, event, { upstreamName, isBackup, peerId, down })
end

-- 需要通知其他worker进程更新缓存中的dynamic_server信息
function _M:dynamicUpsChangeEvent(upstreamName)
    local event = EVENTS.DYNAMIC_UPS_UPDATE or EVENTS.DYNAMIC_UPS_DEL
    self.observer.post(EVENTS.DYNAMIC_UPS_SOURCE, event, upstreamName)
end

-- 获取所有运行时信息,这个方法最多会获取1024条信息
function _M:getAllRuntimeInfo()
    local result = {}
    local upsNames = SHARED_DICT:get_keys()
    for _, name in ipairs(upsNames) do
        name = string.gsub(name, "dynamic_ups_cache", "")
        local info = self:getUpstreamServers(name)
        result[name] = info
    end
    return result
end

-- 关闭指定的peer，暂时不参与负载均衡
function _M:setPeerDown(upstreamName, peerId, down, isBackup)
    -- 查询L2
    local _, err, upstreamInfo = self.cache:peek(upstreamName)
    local ok
    if upstreamInfo == "stable" then
        ok, err = ngx_upstream.set_peer_down(upstreamName, isBackup, peerId, down)
        if ok then
            self:peerStateChangeEvent(upstreamName, isBackup, peerId, down)
        end
    else
        if not upstreamInfo then
            -- 查询DB
            upstreamInfo, err = self.dao:getUpstreamServers(upstreamName)
            if err or upstreamName == nil then
                err = "查询upstream出错！可能是不存在upstreamName:" .. upstreamName
                LOGGER(ERR, err)
                return ok, err
            end
        end
        -- 更新db
        local weight
        weight, err = self.dao:downUpstreamServer(upstreamName, peerId, down)
        if not err then
            if down then weight = 0 end
            self:getUpstreamBalancer(upstreamName):set(peerId, weight)
            self:peerStateChangeEvent(upstreamName, peerId, weight)
            ok = true
        end
    end
    return ok, err
end

-- 刷新缓存
function _M:refreshCache(upstreamName)
    local res, err = self.dao:getUpstreamServers(upstreamName)
    -- 更新缓存
    if err then
        LOGGER(ERR, "could not retrieve upstream servers:", err)
    elseif res == nil then
        LOGGER(ERR, "could not find upstream servers")
    else
        self.cache:set(upstreamName, nil, res)
        -- 通知其它worker更新缓存
        self:dynamicUpsChangeEvent(upstreamName)
    end
end

-- 动态添加upstream中的server
function _M:addUpstreamServers(upstream, servers)
    -- 查询
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local ok
    if not err then
        if upstreamInfo == "stable" then
            err = "暂不支持对配置文件中的upstream进行编辑！"
        else
            ok, err = self.dao:addUpstreamServers(upstream, servers)
            if ok then
                --通知其它worker进行更新缓存,并且重建balancer
                self:refreshCache(upstream)
            end
        end
    else
        LOGGER(ERR, "查询upstream信息出现错误，err:", err)
    end
    return ok, err
end

-- 动态添加upstream中的server
function _M:delUpstreamServers(upstream, servers)
    -- 查询
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local ok
    if not err then
        if upstreamInfo == "stable" then
            err = "暂不支持对配置文件中的upstream进行编辑！"
        else
            ok, err = self.dao:delUpstreamServers(upstream, servers)
            if ok then
                --通知其它worker进行更新缓存,并且重建balancer
                self:refreshCache(upstream)
            end
        end
    else
        LOGGER(ERR, "查询upstream信息出现错误，err:", err)
    end
    return ok, err
end

-- 查询upstream中的所有server信息
function _M:getUpstreamServers(upstream)
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local data
    if upstreamInfo then
        if upstreamInfo == "stable" then
            data = {}
            data["primary"] = ngx_upstream.get_primary_peers(upstream)
            data["backup"] = ngx_upstream.get_backup_peers(upstream)
        else
            data = self.dao:getUpstreamServers(upstream)
        end
    else
        err = "不存在的upstream！"
    end
    return data, err
end

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function() return {} end
end

local function newBalancer(res)
    --[[
        {
            "host:port":"str"
        }
    ]]
    if type(res) == "table" then
        print("....",pretty_write(res))
        local server_list = new_tab(0, #res)
        local strategy, mapper, tag
        for k, v in pairs(res) do
            if k == "strategy" then
                strategy = v
            elseif k == "mapper" then
                mapper = v
            elseif k == "tag" then
                tag = v
            else
                --                local hostAndPort = split(k, ":")
                --                server.host = hostAndPort[1]
                --                server.port = hostAndPort[2]
                --                server.down = info.down
                --                server.weight = info.weight
                --                server.max_fails = infos.max_fails
                --                server.fail_timeout = infos.fail_timeout
                --                server.backup = infos.ackup
                if not v.down then
                    server_list[k] = v.weight
                end
            end
        end
        return balancer_warpper:new(strategy, server_list, mapper, tag)
    else
        return res
    end
end

-- 获取upstream信息
function _M:getUpstreamBalancer(upstream)
    local result, err = self.cache:get(upstream, nil, function()
        local res, err = self.dao:getUpstreamServers(upstream)
        if err then
            -- 查询出现错误，10秒内不再查询
            LOGGER(ERR, "could not retrieve upstream servers:", err)
            return nil, err, 10
        end
        return res
    end)
    return result, err
end

local class = {}
function class:new(ref, config)
    local cache, err = mlcache.new("dynamic_ups_cache", PHI_UPSTREAM_DICT_NAME, {
        lru_size = config.router_lrucache_size or 1000, -- L1缓存大小，默认取1000
        ttl = 0, -- 缓存失效时间
        neg_ttl = 0, -- 未命中缓存失效时间
        resty_lock_opts = {
            -- 回源DB的锁配置
            exptime = 10, -- 锁失效时间
            timeout = 5 -- 获取锁超时时间
        },
        ipc_shm = PHI_EVENTS_DICT_NAME, -- 通知其他worker的事件总线
        l1_serializer = newBalancer -- 数据序列化
    })
    if err then
        error("could not create mlcache for dynamic upstream cache ! err :" .. err)
    end
    return setmetatable({ dao = ref, cache = cache }, { __index = _M })
end

return class