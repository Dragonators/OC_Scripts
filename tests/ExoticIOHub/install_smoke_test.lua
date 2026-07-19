local files = {
  ["/home/exotic_quark.cfg"] = "return { preserved = true }\n"
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
      if name == "exotic_quark.cfg" then
        error("preserved config must not be downloaded")
      elseif name and name:sub(-4) == ".cfg" then
        content = "return { fresh = true }\n"
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

assert(files["/home/exotic_quark.cfg"] == "return { preserved = true }\n",
  "existing quark config must be preserved")
assert(files["/home/exotic_magmatter.cfg"] == "return { fresh = true }\n",
  "missing MagMatter config must be installed")
for _, name in ipairs({
  "exotic_iohub_common.lua", "exotic_zh_cn.lua", "exotic_quark_iohub.lua",
  "exotic_magmatter_iohub.lua", "quark.lua", "magmatter.lua",
  "EXOTIC_IOHUB.md", "exotic_iohub_install.lua"
}) do
  assert(files["/home/" .. name], "missing installed file: " .. name)
end
assert(not directories["/home/.exotic-iohub-install-stage"], "stage directory must be removed")
assert(not directories["/home/.exotic-iohub-install-rollback"], "rollback directory must be removed")

print("install_smoke_test: transactional install and config preservation passed")
