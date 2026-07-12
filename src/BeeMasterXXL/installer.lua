-- BeeMasterXXL fixed offline package guard.
-- This package already contains every required source file. The upstream installer
-- would download main again and overwrite the local fixes, so it is intentionally
-- disabled here.

io.stderr:write([[
此目录已经是完整的 BeeMasterXXL 修改版，无需再次联网安装。

请将本目录全部文件（包括 lib 子目录）复制到 OpenComputers 硬盘的 /home，
检查并合并 config.lua 中的生态之书页码，然后运行：

cd /home
bee

不要用上游 installer.lua 覆盖本包，否则固定世界加速器和雄蜂筛选补丁会丢失。
]])
