package.path = "/home/?.lua;" .. package.path

local common = require("exotic_iohub_common")

return common.run({
  mode = "magmatter",
  title = "诸神之锻炉 · 磁物质自动化"
}, "/home/exotic_magmatter.cfg")
