package.path = "/home/?.lua;" .. package.path

local common = require("exotic_iohub_common")

return common.run({
  mode = "quark",
  title = "诸神之锻炉 · 简并夸克胶子等离子体自动化"
}, "/home/exotic_quark.cfg")
