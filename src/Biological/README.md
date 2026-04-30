# 培养缸放射仓自动化

文件：

* `culture_vat.lua`：OpenOS 主程序。
* `culture_vat_config.lua`：中文配置样例。

## 当前模型

程序只使用样板模式，并按“机器组”管理：

* 一个 `group` 对应一个 AE 编码处理样板、一套产物流体阈值、一个组控制 GT 无线红石频率。
* 一个 `group` 内可以有一台或多台培养缸，也可以有一个或多个放射仓。
* 机器开关不再通过 Adapter 直接控制机器，而是由 `group.control` 控制 GT 无线红石频率，再由无线控制覆盖版绑定到机器。
* 机器是否真的在工序中，默认由 `group.active` 读取 GT 无线红石频率。推荐由这一组的设备活跃探测无线覆盖版输出该信号。
* 不再使用 `gt_energyContainer`，也不依赖通用 GT 机器进度 API。

## GT 无线红石

如果安装了 Programmable Hatches，推荐在 OC 电脑里安装它提供的 GT Redstone Card。该卡暴露 `gtredstone` 组件，程序会调用：

* `setWireless(frequency, signal, isPublic)`：写入 GT 无线红石强度。
* `getWireless(frequency, isPublic)`：读取 GT 无线红石强度。

因此组控制默认使用：

```lua
control = {
  mode = "gt_wireless",
  frequency = 1234,
  isPublic = true,
  on = 15,
  off = 0
}
```

这比 OC 自带无线红石接口更适合 GT 无线控制覆盖版。

机器活跃检测也默认使用同一个 `gtredstone` 组件，并推荐写在组级：

```lua
active = {
  mode = "gt_wireless",
  frequency = 2234,
  isPublic = true,
  threshold = 0
}
```

`threshold = 0` 表示无线红石强度大于 0 就视为机器组正在工序中。`gtredstone` 组件通常是唯一的，所以配置里不需要写 `address`。如果某台机器确实要单独判断，可以在该机器下写 `active = {...}` 覆盖组级配置。

## 样板推导

在 `group.pattern` 中指定 ME 接口地址前缀和样板槽位。

* 程序读取样板第一个输出，作为 AE 产物流体匹配目标。
* 程序读取样板最后一个输入；如果数量为 `64`，则视为放射仓材料。
* 如果最后一个输入不是 `64`，该配方视为不需要放射仓材料，最后一个输入也会参与普通原料门控。
* 样板中其他输入会作为原料门控。AE 中同名物品或同名流体数量不足时，不启动机器组，也不向放射仓投料。

当前仓库里的 AE 样板转换器只能读到“显示名”和数量，所以匹配依赖显示名。首次部署时请观察程序 `stat` 输出中的 `product` 和 `radio` 是否与 AE 网络显示名一致。

## 阈值逻辑

* `upper`：AE 中产物流体达到或超过该值时关闭组控制信号。
* `lower`：AE 中产物流体达到或低于该值时尝试开启组控制信号。
* 任一值为 `nil` 时，对应方向的自动切换禁用。
* 如果达到开机条件但样板普通输入不足，程序会保持停机并按 `intervals.product` 周期重新检查。

## 放射仓逻辑

* 组已开机、样板普通输入充足、组处于启动宽限或活跃状态时，程序会让组内机器对应的放射仓保持 `targetCount` 份放射材料。
* 组级活跃信号消失且超过 `work.startGrace` 后，程序会回收该组对应放射仓内的放射材料。
* 如果原料恢复但组仍未活跃，程序会按 `work.retryInterval` 周期重新短暂投放放射材料，给机器重新进入工序的机会。
* 如果多个机器共享同一个放射仓，只要共享者中仍有机器活跃或处于启动宽限，程序不会回收该放射仓材料。

## 配置映射

最省配置的方式是：

* 在 `group.hatches` 写入与 `group.machines` 数量相同的放射仓 ID，程序会按顺序一一对应。
* 如果机器需要多个放射仓，在单台机器里写 `hatches = {"radio_a", "radio_b"}`。
* 如果多台机器共用同一个放射仓，让这些机器引用同一个 hatch ID，或把 `group.hatches` 写成单个共享列表并关闭按索引映射。

## 常用命令

```sh
components
components -l
lua /path/to/culture_vat.lua /path/to/culture_vat_config.lua
```

配置中可以使用地址前缀，不必填写完整地址，只要该前缀在对应组件类型中唯一即可。
