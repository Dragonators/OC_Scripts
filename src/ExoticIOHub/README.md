# 磁物质与简并夸克胶子等离子体：IO 枢纽完整替换方案

适用版本：GTNH 2.8.4、Programmable Hatches `0.1.3p57`、OpenComputers
`1.11.20-GTNH`。两个入口脚本互相独立，但共用同一套控制模块。

## 文件与安装

把以下公共文件放在 OpenOS 的 `/home/`：

- `exotic_iohub_common.lua`
- `exotic_zh_cn.lua`

把两个入口也放在 `/home/`：

- `exotic_quark_iohub.lua`：简并夸克胶子等离子体
- `exotic_magmatter_iohub.lua`：磁物质
- `quark.lua`、`magmatter.lua`：使用 `/home` 配置的短命令入口

把对应的 `*.example.cfg` 复制为 `/home/exotic_quark.cfg` 或
`/home/exotic_magmatter.cfg`，再填写组件地址。运行：

```sh
quark
magmatter
```

地址必须来自 `components -l`。一个网络中存在多个同类组件时不可留空。

## 硬件拓扑

```text
机器物品输出总线 ──物品管道──┐
机器流体输出仓   ──流体管道──┼──> [ IO Hub ] >──正面对正──< [ OC 二合一输入枢纽 ]
主网 AE 线       ────────────┤                                    │
OC 服务器/线缆   ────────────┘                                    └─机器结构输入位
```

- IO Hub 和 OC 二合一输入枢纽都需要 AE 频道，共预留两个频道。
- 两个枢纽正面相对；此连接同时承担 AE 与 OC 网络连接。
- 输出管道直接把提示物送入 IO Hub 自带的 32 个物品槽和 8 个流体槽。
- 同一输出仓随后产生的熔融磁物质或简并夸克胶子等离子体会被识别为成品并送回主网，
  不会被当作下一轮提示物。
- 所有粉末和流体提示物都由 IO Hub 的 `sendItems` / `sendFluids` 完整送回 AE 主网。
- 二合一输入枢纽是该模块唯一的配方输入；不要再安装进阶存储输入仓。
- 不需要物质聚合器、转运器、主网 ME 接口、合成监控器或大型原料缓存仓。

此版本明确选择回收诸神之锻炉生成的提示物：简并夸克胶子模式会把随机粉末和
流体留在主网；磁物质模式会额外留下粉末。它们是实际物品/流体，因此会形成净
材料收益。本方案按使用者选择保留该行为，不再执行销毁。

## AE 样板

主网必须能合成每一种可能需要的 `ae2fc:fluid_drop` 等离子体液滴。脚本先按
液滴的服务器 `name + label` 查找样板，再反复请求一份加工样板，直至网络库存
达到本轮的精确需求。因此建议每份等离子体加工样板输出较大的整批流体。

建议建立并命名专用 CPU `Exotic Plasma`。脚本会等待该 CPU 空闲，超时时也只会
取消这个明确命名的 CPU；配置为空时不会取消可能属于其他生产线的 CPU。

脚本不会把 AE2FC 液滴直接交给二合一输入枢纽。液滴只用于查找样板；实际提交
使用动态生成的 `IC2:itemFluidCell` NBT 引用。所有需求通过 `addTask` 排队后由
`submitTask()` 在同一 tick 送进同一个双输入库存。

当前 p57 的 `addTask` 数据库索引在 Java 侧直接传给 `getStackInSlot`，因此是
0-based；共享模块已经把 OpenOS 数据库的 1-based 配置槽位减一，配置文件仍按
玩家看到的 1-based 槽位填写。

## 两种模式的差异

简并夸克胶子模式要求 IO Hub 中稳定出现总计 7 种提示物：

- 流体提示：对应等离子体数量为提示量 × 1000 L。
- 粉末提示：对应等离子体数量为物品数 × 1296 L。
- 解析成功后，7 种提示物全部送回 AE 主网。

磁物质模式只接受一个粉末、富快子时间流体和扩大化空间流体：

- 等离子体数量为 `(空间流体量 - 时间流体量) × 144 L`。
- 粉末、时间流体和空间流体全部完整送回主网。
- 时间和空间流体随后与等离子体同批提交到双输入库存；粉末保留在主网。

粉末解析顺序为：运行环境提供的矿辞、BartWorks 元数据表、GT++ 物品名、GT
等离子单元元数据探针。该顺序兼容当前 OpenComputers 默认关闭
`insertIdsInConverters` 的配置。

共享模块按 OpenOS 的真实语义检查回调：`component.methods()` 返回的 `false`
表示回调存在但不是 direct，只有返回 `nil` 才表示回调缺失。组件代理中的回调
可以是带 `__call` 的可调用表，因此脚本不使用 `type(method) == "function"` 判断
回调是否存在。

## GUI 与恢复

GUI 最低需要 80×25，推荐 120×35。缺失样板使用当前整合包
`fluid.plasma.*` 中文语言键和 AE2FC 的 `%s液滴` 格式显示。

- `Space`：暂停/继续状态机；不会中断已经开始的 GT 配方。
- `R`：在故障或等待启动状态尝试安全退款，再根据周期日志恢复。
- `Q` / `Esc`：退出并保留周期日志，不会擅自清空枢纽。

脚本把未完成周期写入配置的 `journalPath`。重启后：

- 机器正在运行时继续等待完成。
- 原料已提交但机器未开始时继续等待，不重复提交。
- 提示物尚完整时继续处理。
- 提示物已处理且双输入为空时从库存补充阶段继续。
- 日志、IO Hub 和机器状态不一致时进入故障锁定，不会回送未知物品。

如果 `submitTask()` 返回任何非 `executed` 状态，脚本立即调用 `refund()`；退款
不能完全返回主网时保持故障现场，必须人工检查 AE 容量、频道和安全终端权限。

## 上机自检

先在 OpenOS 中确认实际 API：

```lua
local component = require("component")
local io = component.proxy(component.list("iohub", true)())
local dual = component.proxy(component.list("dualhatch", true)())
for name in pairs(component.methods(io.address)) do print("iohub", name) end
for name in pairs(component.methods(dual.address)) do print("dualhatch", name) end
```

首次运行前确认：IO Hub 只含本机刚输出的提示物，二合一输入枢纽为空，数据库
至少有 9 个槽位，AE 物品与流体存储均有接收空间，两个 AE 设备均在线且专用
CPU 可见。

数据库的 Java `size()` 是内部接口，并不是 Lua 回调。脚本通过
`computer.getDeviceInfo()[数据库地址].capacity` 检查实际容量，不会要求数据库
组件暴露不存在的 `size` 回调。

## 离线测试

仓库测试使用 Lua 5.2 兼容的 Fengari 运行：

```powershell
npx -y --package fengari-node-cli fengari scripts/opencomputers/tests/exotic_iohub_common_test.lua
npx -y --package fengari-node-cli fengari scripts/opencomputers/tests/exotic_runtime_smoke_test.lua
```

核心测试覆盖 GT、GT++、BartWorks 映射、三种换算、中文宽度与回退、任务结果
校验；运行时模拟使用真实的“可调用回调表”和 direct 布尔值，覆盖两个完整周期，
以及错误脚本、脏启动、缺失样板、CPU 忙碌、
合成失败/取消/超时/产量不足、AE 或组件断线、部分提交、退款失败和机器超时。
模拟测试不能替代最终上机验收；正式投产前仍应各跑一轮，并核对双输入库存与 AE
流体账目。
