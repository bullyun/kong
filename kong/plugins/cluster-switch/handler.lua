local constants = require "kong.constants"
local BasePlugin = require "kong.plugins.base_plugin"
local http = require "resty.http"
local cjson = require "cjson.safe"
local pl_stringx = require "pl.stringx"
local url = require "pl.url"
local iputils = require "resty.iputils"

local kong = kong
local type = type

local ClusterSwitchHandle = BasePlugin:extend()

ClusterSwitchHandle.PRIORITY = 50
ClusterSwitchHandle.VERSION = "0.0.1"

--local apollo_address = "52.81.60.236:30011"
--local apollo_address = "apollo-configservice.apollo.svc.cluster.local:8080"


-- http请求，返回json，失败返回nil
local function http_request(method, url, timeout)
  local httpc = http.new()
  httpc:set_timeouts(10000, 10000, timeout);
  local res, err = httpc:request_uri(url,
    {
      method = method,
      keepalive = false
    }
  )
  if not res then
    return nil
  end
  if res.status ~= 200 then
    return nil
  end

  ngx.log(ngx.DEBUG, "ClusterSwitch: read config. body=" .. res.body)

  local json_res, err = cjson.decode(res.body)
  if not json_res then
    return nil
  end
  return json_res
end


-- 刷新配置
-- 测试的时候改成全局的
local function refresh_config()

  ClusterSwitchHandle.cluster_config = ClusterSwitchHandle.cluster_config or {}
  ClusterSwitchHandle.notification_id = ClusterSwitchHandle.notification_id or -1

  -- 查询是否有更新，等待60秒
  local notifications = "[{\"namespaceName\":\"" .. ClusterSwitchHandle.apollo_namespace .. "\", \"notificationId\":" .. tostring(ClusterSwitchHandle.notification_id) .. "}]"
  notifications = url.quote(notifications)
  local notify_res = http_request("GET",
    "http://" .. ClusterSwitchHandle.apollo_address .. "/notifications/v2" ..
      "?appId=" .. ClusterSwitchHandle.apollo_app_id ..
      "&cluster=" ..ClusterSwitchHandle.apollo_cluster ..
      "&notifications=" .. notifications,
    61000)
  if not notify_res then
    ngx.log(ngx.INFO, "ClusterSwitch: get notifications failed")
    return
  end

  -- 获取配置
  local config_res = http_request("GET",
    "http://" .. ClusterSwitchHandle.apollo_address ..
      "/configs/" .. ClusterSwitchHandle.apollo_app_id ..
      "/" .. ClusterSwitchHandle.apollo_cluster ..
      "/" .. ClusterSwitchHandle.apollo_namespace,
    10000)
  if not config_res then
    ngx.log(ngx.WARN, "ClusterSwitch: get config failed")
    return
  end
  if not config_res.configurations or type(config_res.configurations) ~= "table" then
    ngx.log(ngx.WARN, "ClusterSwitch: analysis config failed")
    return
  end

  -- 配置保存
  if config_res.configurations["bullyunwork.current.cluster"] == "blue" then
    ClusterSwitchHandle.cluster_config.cluster = "blue"
  else
    ClusterSwitchHandle.cluster_config.cluster = "green"
  end
  ClusterSwitchHandle.cluster_config.blue = ClusterSwitchHandle.cluster_config.blue or {}
  if config_res.configurations["cluster.blue.whitelist.enable"] == "1" then
    ClusterSwitchHandle.cluster_config.blue.ips = iputils.parse_cidrs(pl_stringx.split(config_res.configurations["cluster.blue.whitelist.ips"], ","))
  else
    ClusterSwitchHandle.cluster_config.blue.ips = nil
  end
  ClusterSwitchHandle.cluster_config.green = ClusterSwitchHandle.cluster_config.green or {}
  if config_res.configurations["cluster.green.whitelist.enable"] == "1" then
    ClusterSwitchHandle.cluster_config.green.ips = iputils.parse_cidrs(pl_stringx.split(config_res.configurations["cluster.green.whitelist.ips"], ","))
  else
    ClusterSwitchHandle.cluster_config.green.ips = nil
  end

  -- 保存通知ID，下次请求变化用
  ClusterSwitchHandle.notification_id = notify_res[1]["notificationId"];

  ngx.log(ngx.INFO, "ClusterSwitch: update config. notification_id=" .. tostring(ClusterSwitchHandle.notification_id))
end

local function init_refresh_config()
  if not ClusterSwitchHandle.apollo_address then
    return
  end
  if ClusterSwitchHandle.cluster_config then
    return
  end

  ngx.log(ngx.INFO, "ClusterSwitch: apollo address " .. ClusterSwitchHandle.apollo_address)
  refresh_config()

  --ngx.timer.every(1, refresh_config)
  local handle
  handle = function ()
      refresh_config();
      ngx.timer.at(1, handle)
    end
  local ok = ngx.timer.at(1, handle)
  if not ok then
    ngx.log(ngx.ERR, "ClusterSwitch: start timer failed")
  end
end

local function req_add_header()

  if not ClusterSwitchHandle.cluster_config then
    return;
  end

  -- Implement any custom logic here
  local binary_remote_addr = ngx.var.binary_remote_addr

  local in_blue = ClusterSwitchHandle.cluster_config.blue.ips and iputils.binip_in_cidrs(binary_remote_addr, ClusterSwitchHandle.cluster_config.blue.ips)
  local in_green = ClusterSwitchHandle.cluster_config.green.ips and iputils.binip_in_cidrs(binary_remote_addr, ClusterSwitchHandle.cluster_config.green.ips)

  local cluster
  if in_blue and in_green then
    -- 如果都在两个白名单里面，按当前集群指向来
    cluster = ClusterSwitchHandle.cluster_config.cluster
  elseif in_blue then
    cluster = "blue"
  elseif in_green then
    cluster = "green"
  else
    -- 如果都不在白名单里，通过cluster指向
    cluster = ClusterSwitchHandle.cluster_config.cluster
  end

  ngx.req.set_header("bullyun-cluster", cluster)

  ngx.log(ngx.DEBUG, "ClusterSwitch: add header bullyun-cluster: " .. cluster)
end

function ClusterSwitchHandle:new()
  ClusterSwitchHandle.super.new(self, "cluster-switch-plugin")
end

function ClusterSwitchHandle:init_worker()
  ClusterSwitchHandle.super.init_worker(self)
end

function ClusterSwitchHandle:certificate(config)
  ClusterSwitchHandle.super.certificate(self)

  -- Implement any custom logic here
end

function ClusterSwitchHandle:rewrite(config)
  ClusterSwitchHandle.super.rewrite(self)

  -- 应付配置变化，而且要1分钟后才能生效
  if config and config.apollo_address then
    ClusterSwitchHandle.apollo_address = config.apollo_address
    ClusterSwitchHandle.apollo_app_id = config.apollo_app_id
    ClusterSwitchHandle.apollo_namespace = config.apollo_namespace
    ClusterSwitchHandle.apollo_cluster = config.apollo_cluster

    init_refresh_config();
  end

  -- 集群字段设置
  req_add_header()
end

function ClusterSwitchHandle:access(config)
  ClusterSwitchHandle.super.access(self)

  -- Implement any custom logic here
end

function ClusterSwitchHandle:header_filter(config)
  ClusterSwitchHandle.super.header_filter(self)

  -- Implement any custom logic here
end

function ClusterSwitchHandle:body_filter(config)
  ClusterSwitchHandle.super.body_filter(self)

  -- Implement any custom logic here
end

function ClusterSwitchHandle:log(config)
  ClusterSwitchHandle.super.log(self)

  -- Implement any custom logic here
end

return ClusterSwitchHandle
