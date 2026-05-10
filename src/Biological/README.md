# 培养缸放射仓自动化

本目录包含 OpenComputers / GTNH 环境下使用的培养缸放射仓自动化脚本。

- `culture_vat.lua`：主程序，复制到 OpenOS 电脑后运行。
- `../culture_vat_config.lua`：示例配置，可复制为 `/etc/culture_vat_config.lua` 后修改。

## 运行方式

```sh
lua culture_vat.lua /etc/culture_vat_config.lua
```

如果不传配置路径，程序会依次尝试读取：

- `/etc/culture_vat_config.lua`
- `culture_vat_config.lua`
- `./culture_vat_config.lua`

配置中的时间单位都是秒，不是 tick。

## 需要的组件

- 一个 OC 电脑或服务器。
- 一个可访问 AE 网络的 `me_controller` 或 `me_interface` 组件，用于读取物品和流体库存。
- 一个放置编码处理样板的 ME 接口，程序通过 `getInterfacePattern` 读取样板。
- 一个 OC `database` 组件，用于临时保存样板中的放射仓材料描述。
- Programmable Hatches 的 `gtredstone` 组件，用于读写 GT 无线红石频率。
- 每个机器组一个无线控制覆盖版频率，用于开关这一组培养缸。
- 每个机器组一个设备活跃探测无线覆盖版频率，用于判断这一组机器是否真的处于工序中。
- 每个放射仓旁的 IO Hub。当前脚本通过 IO Hub 从 AE 请求物品，再把物品推入相邻放射仓。

组件地址请优先用 OpenOS 的 `components -l` 查看。分析器看到的地址可能是方块或连接节点地址，不一定是 OC 组件地址。

## 样板规则

程序只支持样板模式：

- `group.pattern` 指向 ME 接口中的编码处理样板。
- 样板第一个输出默认作为产物流体，用于 AE 流体库存阈值判断。
- 样板最后一个输入如果数量为 `64`，视为放射仓材料。
- 样板最后一个输入如果数量不是 `64`，则不启用放射仓材料逻辑，并把它当作普通输入。
- 除放射仓材料外，其他样板输入都会作为原料门控条件。

流体匹配会对 `drop of ...`、`drops of ...`、`fluid drop of ...` 等显示名前缀做归一化；如果仍然提示缺流体，通常需要检查 AE 组件实际返回的流体显示名。

## 机器组与放射仓

当前推荐配置是组级绑定，不再维护“机器 -> hatch”的一一映射：

```lua
groups = {
  {
    name = "vat_group_1",
    hatches = {"radio_a", "radio_b"},
    machines = {
      {name = "vat_1"},
      {name = "vat_2"}
    }
  }
}
```

含义是：`radio_a` 和 `radio_b` 共同服务 `vat_group_1` 整组机器。多台机器共用一个放射仓时，`hatches` 里只写这个 hatch 一次即可。

`machines` 仍然需要保留，主要用于：

- 计算 `inputBatches = "machines"` 时需要多少批原料。
- 状态日志里显示机器数量。
- 如果以后某台机器需要单独活跃信号，可以在该 machine 下配置 `active`。

`machine.name` 只用于日志和状态显示，不参与放射仓映射。

## 阈值与启停

每组通过 `thresholds` 控制启停：

- `upper`：AE 中产物流体数量达到或超过该值时关闭控制信号。
- `lower`：AE 中产物流体数量达到或低于该值时开启控制信号。
- `upper = nil` 表示不自动停机。
- `lower = nil` 表示不自动开机。

如果上下限都配置，`upper` 应大于等于 `lower`，形成滞回区间，避免频繁开关。

## 原料门控与空转保护

启动前，程序会检查 AE 中是否有足够的样板普通输入。默认 `inputBatches = "machines"`，即按组内机器数量放大需求。

运行中如果原料不足：

- `forceOffOnUnsafe = true`：关闭组控制信号。
- `forceOffOnUnsafe = false`：不关闭组控制信号，只停止继续向放射仓投料。

原料恢复后，程序会按 `machine` 检测间隔和 `retryInterval` 继续尝试投放放射仓材料，使机器重新进入工序。

## 放射仓投料行为

脚本不会尝试从 Radio Hatch 抽取物品，因为实际测试中放射仓通常只能导入，不能导出。

每次投料前，程序会通过 IO Hub 检查目标槽：

- 目标槽为空：从 AE 请求 1 个放射仓材料并推入。
- 目标槽已有正确材料且数量不超过 `targetCount`：不投料。
- 目标槽已有正确材料但数量超过 `targetCount`：输出 warning，不抽取，等待自然消耗。
- 目标槽是其他物品：输出 error，不投料，需要手动处理或等待结构自行消耗。

常用 hatch 配置：

```lua
hatches = {
  radio_a = {
    ioHub = "05abc",   -- IO Hub 组件地址前缀，来自 components -l
    side = sides.east, -- 从 IO Hub 看向放射仓的方向
    hatchSlot = 1
  }
}
```

## 常见问题

`no component found for type=iohub`：
使用 `components -l` 中显示的 `iohub` 组件地址前缀，不要使用分析器显示的方块地址。

`cannot request ... from AE via IO Hub`：
检查 IO Hub 是否连入 AE 网络、AE 是否有该物品、样板最后一个 64 输入是否是正确材料、IO Hub 缓冲槽是否可用。

`cannot drop ... into side=... slot=...`：
检查 IO Hub 是否贴着正确的放射仓、`side` 是否是从 IO Hub 看向放射仓的方向、`hatchSlot` 是否正确。

`input missing: drop of ...`：
检查 AE 网络是否真的能被 OC 组件读取到该流体。脚本会做流体显示名归一化，但不同环境返回名仍可能不同。

`contains a different item`：
放射仓目标槽里不是样板推导出的放射材料。脚本会跳过投料，不会抽取。

`contains N radio items, target=1`：
目标槽里已有过量正确材料。脚本只报警并停止追加，等待自然消耗。
