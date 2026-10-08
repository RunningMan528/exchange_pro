# 交易所 Flutter 客户端 Demo

对照 `Totoro_flutter.html` 中 **Bitunix 交易所 Flutter 客户端** 的项目职责实现的可运行 Demo，
用具体案例讲清楚：实时订单簿、WebSocket 连接管理、合约交易、订单/持仓同步与性能优化。

纯逻辑核心在 `lib/core/`（不依赖 Flutter），已通过 `tool/verify.dart` 全部验证；
UI 层在 `lib/app/`，已通过 `dart analyze lib/` 零错误。

## 运行方式

```bash
# 1. 拉依赖并运行
flutter pub get
flutter run
```

Demo 内置 `MockMarketFeed` 模拟交易所服务端，**无需联网**即可演示行情、订单簿、
合约下单、持仓盈亏与断线重连；每隔一段时间会自动制造一次 seq 缺口和服务端断线，
便于观察客户端重订阅/重连行为。

项目已包含 Android、iOS、Web、Windows、macOS 和 Linux 平台工程。可用
`flutter devices` 查看当前机器可运行的设备，并通过 `flutter run -d <device-id>`
选择目标平台。桌面端构建需要在对应操作系统执行：Windows 构建需 Windows，
Linux 构建需 Linux，iOS/macOS 构建需 macOS。

## 目录结构

```
lib/
├── main.dart                     # 入口
├── core/                         # 纯 Dart，可单测（不 import flutter）
│   ├── models.dart               # Order/Trade/Position/Account/Ticker 等模型
│   ├── order_book_engine.dart    # 快照+增量合并、Sequence 校验、Top-N 聚合
│   ├── ws_connection.dart        # 连接状态机：心跳、指数退避重连、重订阅
│   ├── market_feed.dart          # Mock 服务端：快照/增量/缺口/断线
│   ├── contract_engine.dart      # 开平仓合并、未实现盈亏、强平价、保证金
│   └── throttle.dart             # BatchBuffer(批处理) / Throttler(节流)
├── app/                          # Flutter UI 层
│   ├── market_store.dart         # 行情仓库（状态拆分 + 批处理）
│   ├── trade_store.dart          # 交易仓库（订单/持仓/账户）
│   ├── exchange_screen.dart      # 页面：行情栏/K线/盘口/下单/持仓/订单
│   ├── order_book_painter.dart   # 盘口 CustomPainter（局部刷新）
│   └── kline_painter.dart        # K 线 CustomPainter
└── ...
tool/
└── verify.dart                   # 纯 Dart 自测脚本：dart tool/verify.dart
```

## 关键技术与对应代码

### 1. 实时订单簿：Snapshot + Incremental Update + Sequence 校验
- 位置：`lib/core/order_book_engine.dart`
- 服务端先推快照，之后推增量；每条消息带单调递增 `seq`。
- `applyDelta` 规则：
  - `seq == lastSeq + 1` → 应用（`size==0` 删档位，否则 upsert）；
  - `seq <= lastSeq` → 过期消息丢弃；
  - `seq > lastSeq + 1` → 缺口，通知上层重订阅、重新拉快照。
- 用 `SplayTreeMap` 维护买盘降序/卖盘升序，`Top-N` + `tickSize` 聚合取盘口。

### 2. 实时行情：多频道订阅 + 连接管理（心跳 / 断线重连 / 订阅恢复）
- 位置：`lib/core/ws_connection.dart` + `lib/app/market_store.dart`
- `ticker / trade / kline / depth` 多频道订阅；`subscribe` 消息驱动。
- 心跳：定时发 `{"op":"ping"}`，收到 `pong` 取消超时；超时判定假死 → 强制重连。
- 重连：指数退避 `base * 2^(n-1)` + 随机抖动（避免惊群）；重连成功回调 `onResubscribe`
  恢复订阅，depth 频道重新收快照。

### 3. 合约交易：限价/市价、杠杆、全仓/逐仓、TP/SL
- 位置：`lib/core/contract_engine.dart` + `lib/app/trade_store.dart` + 交易面板
- 下单支持限价/市价、开多/开空、只减仓、杠杆滑杆、全仓/逐仓、止盈止损。
- 开仓同向合并算加权平均价；平仓结算已实现盈亏；`liquidationPrice` / `initialMargin`
  用于展示强平价与占用保证金。

### 4. 订单与持仓状态实时同步
- 位置：`lib/app/trade_store.dart`
- 持仓 `size>0` 多 / `size<0` 空，标记价更新时重算未实现盈亏与账户可用余额。
- 订单/持仓列表用 `ChangeNotifier` 局部刷新（与行情仓库解耦）。

### 5. K 线图表：周期选择 + 手动横向滑动
- 位置：`lib/app/kline_painter.dart` + `lib/app/exchange_screen.dart` + `lib/app/market_store.dart`
- 提供 `15分 / 1时 / 4时 / 1日 / 1月` 五档周期，切换时会清空旧图并重新订阅对应历史数据。
- 使用 CustomPainter 绘制窄实体、上下影线、价格网格、时间刻度和最新价标线。
- 图表使用固定视窗和横向滚动，只在初始或切换周期时定位到最新价格，之后由用户手动滑动。
- 实时行情只更新当前时间戳对应的最后一根蜡烛，周期结束后才追加新蜡烛，避免图表持续滚动。
- K 线使用独立 `klineVersion` 和 `klineIntervalNotifier`，避免和盘口、成交高频刷新互相影响。

### 6. 性能优化：数据批处理 + 局部刷新 + 状态拆分
- 位置：`lib/core/throttle.dart` + `lib/app/market_store.dart` + `order_book_painter.dart`
- **批处理**：`BatchBuffer` 把 100ms 窗口内的多条深度增量合并为一次 `applyDelta` + 一次刷新。
- **局部刷新**：订单簿用 `RepaintBoundary` + `CustomPainter.shouldRepaint(version)`，
  盘口版本不变时跳过重绘，且不随其它区域重绘。
- **状态拆分**：`MarketStore`（行情）与 `TradeStore`（交易）分离；高频盘口用独立
  `ValueNotifier<int> bookVersion` 通知，Ticker 与 K 线分别使用独立
  `ValueNotifier`，只有真正变化的区域才 rebuild。

## 自测

```bash
dart tool/verify.dart
```

覆盖：快照/增量/过期/缺口、盈亏与强平价、批处理合并、心跳保活、断线重连与重订阅。
