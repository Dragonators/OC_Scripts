# BeeMasterXXL 固定世界加速器修改版

本包基于 BeeMasterXXL 上游提交 `f19f3dd2ce4ea65204f5bb1545d0fff89d2093c1`，包含运行所需的全部 Lua 文件和 `lib` 子目录。

## 联网安装（推荐）

机器人安装 Internet Card 后，在 OpenOS 中执行：

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/beemasterxxl-fixed-v2/src/BeeMasterXXL/install.lua /tmp/beemaster-install.lua
lua /tmp/beemaster-install.lua /home
```

联网安装器会保留已有 `config.lua` 的生态之书页码；旧配置缺少 `worldAccelerator_mode` 时会备份配置并自动加入 `fixed`。它不会修改 `data.txt`。

## 安装

1. 先备份 OpenComputers 硬盘中的 `config.lua` 和 `data.txt`。本包不含 `data.txt`，不会主动覆盖已有进度。
2. 在宿主机解压 ZIP，再通过软盘、服务器存档文件桥或你平时使用的 OC 文件传输方式，将解压出的全部文件（包括 `lib` 子目录）放到 OC 硬盘的 `/home`。ZIP 本身不是游戏内安装器。
3. 将你原有 `config.lua` 中 `apiary` 的 16 个生态之书页码合并回新配置。包内页码只是上游示例，不一定适合你的世界。
4. 按下文选择世界加速器模式，然后在 OpenOS 中执行：

```sh
cd /home
bee
```

先进入 `/home` 很重要：主脚本会从当前目录加载同目录模块，而依赖库位于 `/home/lib`。

本包的 `installer.lua` 只会显示提示，不会联网下载。不要再运行上游安装器，否则它会用上游 `main` 覆盖这些修改。

## 世界加速器配置

`config.lua` 新增：

```lua
["worldAccelerator_mode"] = "fixed",
["worldAccelerator_tier"] = 5
```

- `fixed`：默认。脚本不拆除、不放置世界加速器。请预先在机器人坐标 `(1,2)`、`(2,4)`、`(4,3)`、`(3,1)` 手动放好四台，并将每台保持在 `TileEntity` 模式。
- `moving`：保留上游行为，机器人在四个位置之间搬运一台世界加速器；此时 `worldAccelerator_tier` 用于匹配物品。

坐标的原点和朝向与原 BeeMasterXXL 布局一致，加速器位于原脚本放置它们的同一高度。固定模式下 AE 网络不必存放世界加速器。

注意：四台固定加速器在脚本退出或报错后仍会留在原地并继续耗电。以 IV（配置等级 5）为例，满速 TileEntity 模式四台合计约 `196,608 EU/t`，供电需要留足余量。

## 雄蜂选择修复

- 候选雄蜂必须同时携带目标品种 `species` 与该品种的原生 `effect`，两个条件都允许位于任一侧等位基因。
- 删除了“只有一个候选就不校验直接返回”的路径。
- 目标 `effect` 也参与优先级评分，纯种目标品种仍优先。
- 没有合格亲本时返回明确错误；重试阶段也会重新校验，不会因 `tag=nil` 拉取任意旧雄蜂。

因此，不符合目标效果的旧蜂可以继续留在 AE 网络中，脚本会忽略它们并重新规划/培育所需品种。

## Lua 架构兼容

上游 `zzlib.lua` 会在 Lua 5.2/LuaJ 下加载 `lib/inflate-bit32.lua`，但 BeeMasterXXL 原仓库漏打包了该文件。本包已从 mason.nvim 的 zzlib vendor 副本补齐它；Lua 5.3 仍使用上游已有的 `lib/inflate-bwo.lua`。

## 修改文件

- `config.lua`
- `apiary.lua`
- `beeData.lua`
- `strategy.lua`
- `installer.lua`（离线包防覆盖提示）
- `readme.md`（本说明）
- `lib/inflate-bit32.lua`（补齐 Lua 5.2/LuaJ 后端）

其余源文件来自上述上游提交，未作修改。
