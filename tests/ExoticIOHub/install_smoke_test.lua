local files = {
  ["/home/fog_quark.cfg"] = [[return {
  mode = "quark",
  preserved = true,
  components = { transposer = "custom-address" },
  timing = {
    poll = 1,
    craftPoll = 1,
    craftWarningAfter = 600,
    cycleSettle = 2,
  },
}
]],
  ["/home/fog_magmatter.cfg"] = [[return {
  mode = "magmatter",
  preserved = "v10",
  components = { transposer = "v10-custom-address" },
  timing = {
    poll = 0.25,
    returnVerifyDelay = 0.1,
    advanceWarningAfter = 30,
    cycleSettle = 0.25,
  },
}
]],
  ["/home/exotic_quark.cfg"] = "legacy v8 config must remain untouched\n"
}
local directories = { ["/"] = true, ["/home"] = true }

local function normalize(path)
  path = tostring(path):gsub("\\", "/"):gsub("/+", "/")
  if #path > 1 then path = path:gsub("/$", "") end
  return path
end

local function parent(path)
  return normalize(path):match("^(.*)/[^/]+$") or "/"
end

local function basename(path)
  return normalize(path):match("([^/]+)$")
end

io.open = function(path, mode)
  path = normalize(path)
  if mode == "wb" then
    local chunks = {}
    return {
      write = function(_, value) chunks[#chunks + 1] = tostring(value); return true end,
      flush = function() return true end,
      close = function() files[path] = table.concat(chunks); return true end
    }
  elseif mode == "rb" and files[path] ~= nil then
    local offset = 1
    return {
      read = function(_, amount)
        if amount == "*a" then
          local result = files[path]:sub(offset)
          offset = #files[path] + 1
          return result
        end
        if offset > #files[path] then return nil end
        local result = files[path]:sub(offset, offset + amount - 1)
        offset = offset + #result
        return result
      end,
      close = function() return true end
    }
  end
  return nil, "not found"
end

package.preload.component = function()
  return {
    isAvailable = function(name) return name == "internet" end,
    internet = { isHttpEnabled = function() return true end }
  }
end

package.preload.shell = function()
  return { resolve = function(path) return normalize(path) end }
end

package.preload.filesystem = function()
  return {
    concat = function(a, b) return normalize(a .. "/" .. b) end,
    exists = function(path)
      path = normalize(path)
      return files[path] ~= nil or directories[path] == true
    end,
    isDirectory = function(path) return directories[normalize(path)] == true end,
    makeDirectory = function(path)
      path = normalize(path)
      directories[path] = true
      return true
    end,
    size = function(path) return #(files[normalize(path)] or "") end,
    remove = function(path)
      path = normalize(path)
      files[path], directories[path] = nil, nil
      return true
    end,
    rename = function(from, to)
      from, to = normalize(from), normalize(to)
      if files[from] ~= nil then
        files[to], files[from] = files[from], nil
        return true
      end
      return false, "source missing"
    end,
    list = function(path)
      path = normalize(path)
      local names, seen = {}, {}
      local prefix = path == "/" and "/" or path .. "/"
      local function collect(candidate, isDirectory)
        if candidate:sub(1, #prefix) ~= prefix then return end
        local rest = candidate:sub(#prefix + 1)
        if rest ~= "" and not rest:find("/", 1, true) then
          local name = rest .. (isDirectory and "/" or "")
          if not seen[name] then names[#names + 1], seen[name] = name, true end
        end
      end
      for candidate in pairs(files) do collect(candidate, false) end
      for candidate in pairs(directories) do collect(candidate, true) end
      local index = 0
      return function() index = index + 1; return names[index] end
    end
  }
end

package.preload.internet = function()
  return {
    request = function(url)
      local name = url:match("/([^/]+)$")
      local content
      if name == "fog_quark.cfg" then
        error("preserved config must not be downloaded")
      elseif name == "fog_magmatter.cfg" then
        error("preserved config must not be downloaded")
      elseif name and name:sub(-4) == ".lua" then
        content = "return true\n"
      else
        content = "installer documentation\n"
      end
      local yielded = false
      return function()
        if yielded then return nil end
        yielded = true
        return content
      end
    end
  }
end

local installer = assert(loadfile("src/ExoticIOHub/install.lua"))
installer("/home")

assert(files["/home/fog_quark.cfg"]:find('transposer = "custom-address"', 1, true),
  "existing quark component configuration must be preserved")
assert(files["/home/fog_quark.cfg"]:find("poll = 0.25", 1, true),
  "v9 default poll must be migrated")
assert(files["/home/fog_quark.cfg"]:find("craftPoll = 0.25", 1, true),
  "v9 default craft poll must be migrated")
assert(files["/home/fog_quark.cfg"]:find("cycleSettle = 0", 1, true),
  "v9 default settle time must be removed")
assert(files["/home/fog_quark.cfg"]:find("returnVerifyDelay = 0.1", 1, true),
  "v10 return verification timing must be added")
assert(files["/home/fog_quark.cfg"]:find("advanceWarningAfter = 30", 1, true),
  "v10 machine-advance warning timing must be added")
assert(files["/home/fog_magmatter.cfg"]:find('transposer = "v10-custom-address"', 1, true),
  "existing v10 MagMatter component configuration must be preserved")
assert(files["/home/fog_magmatter.cfg"]:find("cycleSettle = 0", 1, true),
  "v10 default settle time must be removed")
assert(files["/home/exotic_quark.cfg"] == "legacy v8 config must remain untouched\n",
  "v8 config must not be migrated or modified")
for _, name in ipairs({
  "fog_exotic.lua", "quark.lua", "magmatter.lua",
  "FOG_EXOTIC.md", "fog_exotic_install.lua"
}) do
  assert(files["/home/" .. name], "missing installed file: " .. name)
end
assert(files["/home/quark.lua"]:find("/home/fog_quark.cfg", 1, true),
  "quark compatibility entry point must use the v11 config")
assert(files["/home/magmatter.lua"]:find("/home/fog_magmatter.cfg", 1, true),
  "MagMatter compatibility entry point must use the v11 config")
assert(not directories["/home/.fog-exotic-install-stage"], "stage directory must be removed")
assert(not directories["/home/.fog-exotic-install-rollback"], "rollback directory must be removed")

-- Force one promotion failure. Every previously installed file must be restored,
-- and the following run must recover the ACTIVE marker before reinstalling.
local beforeFailure = {}
for path, content in pairs(files) do beforeFailure[path] = content end

local filesystem = require("filesystem")
local realRename = filesystem.rename
local failOnce = true
filesystem.rename = function(from, to)
  from, to = normalize(from), normalize(to)
  if failOnce and
      from == "/home/.fog-exotic-install-stage/fog_exotic.lua" and
      to == "/home/fog_exotic.lua" then
    failOnce = false
    return false, "simulated promotion failure"
  end
  return realRename(from, to)
end

local realExit = os.exit
os.exit = function(code) error("__INSTALL_EXIT_" .. tostring(code) .. "__", 0) end
local failedRun = assert(loadfile("src/ExoticIOHub/install.lua"))
local failedOK, failedReason = pcall(failedRun, "/home")
assert(not failedOK and tostring(failedReason):find("__INSTALL_EXIT_1__", 1, true),
  "promotion failure must return installer exit code 1")
os.exit = realExit
filesystem.rename = realRename

for path, content in pairs(beforeFailure) do
  assert(files[path] == content, "rollback changed existing file: " .. path)
end
assert(files["/home/exotic_quark.cfg"] == "legacy v8 config must remain untouched\n",
  "rollback must not touch unrelated v8 files")
assert(directories["/home/.fog-exotic-install-rollback"],
  "failed install must leave its recovery journal")

local recoveryRun = assert(loadfile("src/ExoticIOHub/install.lua"))
recoveryRun("/home")
assert(not directories["/home/.fog-exotic-install-stage"], "recovery must remove stage directory")
assert(not directories["/home/.fog-exotic-install-rollback"], "recovery must remove rollback directory")

print("install_smoke_test: v9/v10 migration, config isolation, rollback and recovery passed")
