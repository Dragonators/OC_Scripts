package.path = "/home/?.lua;" .. package.path

local common = require("exotic_iohub_common")

local argv = { ... }
local configPath = argv[1] or "/home/exotic_quark.cfg"

return common.run({
  mode = "quark",
  title = "诸神之锻炉 · 简并夸克胶子等离子体自动化"
}, configPath)
