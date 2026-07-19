package.path = "/home/?.lua;" .. package.path

local common = require("exotic_iohub_common")

local argv = { ... }
local configPath = argv[1] or "/home/exotic_magmatter.cfg"

return common.run({
  mode = "magmatter",
  title = "诸神之锻炉 · 磁物质自动化"
}, configPath)
