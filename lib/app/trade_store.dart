// 模块：合约交易状态仓库
// 作用：管理订单、持仓、保证金、可用余额和未实现盈亏，并模拟市价/限价成交。
// 核心流程：placeOrder -> 判断开仓或平仓 -> ContractEngine 计算 -> _recalcAccount -> 通知 UI。
// 边界说明：当前 Demo 使用本地模拟成交，真实项目应由交易网关、订单推送和账户频道驱动。

import 'package:flutter/foundation.dart';

import '../core/contract_engine.dart';
import '../core/models.dart';

/// 合约交易状态中心。
///
/// 它把 UI 输入转换为订单，通过 [ContractEngine] 更新持仓，再重新计算保证金和
/// 可用余额。任何会引起交易界面变化的状态最终都通过 ChangeNotifier 通知 UI。
class TradeStore extends ChangeNotifier {
  TradeStore({this.initialBalance = 100000});

  final ContractEngine engine = ContractEngine();
  final List<Order> orders = [];
  final List<Position> positions = [];

  double initialBalance;
  double available = 100000;
  double margin = 0;
  double markPrice = 60000;

  // 当前下单参数（由交易面板写入）。
  OrderType orderType = OrderType.limit;
  double leverage = 10;
  MarginMode marginMode = MarginMode.cross;
  double qty = 0.01;
  double price = 60000;
  double? tpPrice;
  double? slPrice;
  bool reduceOnly = false;

  int _orderSeq = 1000;

  /// 接收行情最新价并刷新合约标记价。
  ///
  /// 标记价变化会重新计算持仓未实现盈亏；同时把限价输入同步到最新价，
  /// 方便用户快速以当前价格下单。
  void setMarkPrice(double p) {
    markPrice = p;
    price = p; // 交易面板限价默认跟随最新价。
    // 更新账户未实现盈亏。
    notifyListeners();
  }

  /// 汇总所有持仓在当前标记价下的未实现盈亏。
  double accountUnrealizedPnl() {
    return positions.fold(
        0, (sum, p) => sum + engine.unrealizedPnl(p, markPrice));
  }

  /// 创建一笔模拟订单并更新持仓与账户。
  ///
  /// 订单会根据市价/限价决定成交价，再判断是开仓还是平仓。Demo 直接把订单
  /// 标记为 FILLED；真实实现应改为等待撮合回报并通过推送更新状态。
  void placeOrder(OrderSide side) {
    final order = Order(
      id: 'ORD${_orderSeq++}',
      symbol: 'BTC-USDT',
      side: side,
      type: orderType,
      qty: qty,
      price: orderType == OrderType.limit ? price : null,
      leverage: leverage,
      marginMode: marginMode,
      tpPrice: tpPrice,
      slPrice: slPrice,
      reduceOnly: reduceOnly,
      status: 'FILLED',
    );
    orders.insert(0, order);
    if (orders.length > 100) orders.removeRange(100, orders.length);

    final fillPrice = orderType == OrderType.limit ? (price) : markPrice;

    if (reduceOnly || _isClosing(side)) {
      _closePosition(side, fillPrice);
    } else {
      _openPosition(side, fillPrice);
    }
    _recalcAccount();
    notifyListeners();
  }

  /// 根据现有持仓判断本次订单方向是否属于平仓。
  ///
  /// 买入订单可平空仓，卖出订单可平多仓；如果没有反向持仓则视为开仓。
  bool _isClosing(OrderSide side) {
    for (final p in positions) {
      if (p.size == 0) continue;
      final closeLong = p.isLong && side == OrderSide.sell;
      final closeShort = !p.isLong && side == OrderSide.buy;
      if (closeLong || closeShort) return true;
    }
    return false;
  }

  /// 打开或加仓：优先找到同方向持仓并调用合约引擎合并。
  void _openPosition(OrderSide side, double fillPrice) {
    Position? existing;
    int idx = -1;
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      final sameDir = (p.isLong && side == OrderSide.buy) ||
          (!p.isLong && side == OrderSide.sell);
      if (sameDir && p.size != 0) {
        existing = p;
        idx = i;
        break;
      }
    }
    final merged = engine.open(existing,
        side: side,
        qty: qty,
        price: fillPrice,
        leverage: leverage,
        marginMode: marginMode,
        tpPrice: tpPrice,
        slPrice: slPrice);
    if (idx >= 0) {
      positions[idx] = merged;
    } else {
      positions.add(merged);
    }
  }

  /// 关闭反向持仓并写入已实现盈亏。
  ///
  /// 当前一次只能处理第一个匹配方向；真实交易客户端还应处理多仓合并、
  /// 部分成交、只减仓校验和订单取消竞态。
  void _closePosition(OrderSide side, double fillPrice) {
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      if (p.size == 0) continue;
      final closeLong = p.isLong && side == OrderSide.sell;
      final closeShort = !p.isLong && side == OrderSide.buy;
      if (!closeLong && !closeShort) continue;
      final updated =
          engine.close(p, closeSide: side, qty: qty, price: fillPrice)!;
      positions[i] = updated;
      break;
    }
  }

  /// 重新计算占用保证金、未实现盈亏和可用余额。
  ///
  /// 公式：可用 = 初始权益 - 已占用保证金 + 未实现盈亏。
  void _recalcAccount() {
    margin = positions
        .where((p) => p.size != 0)
        .fold(0.0, (sum, p) => sum + engine.initialMargin(p, markPrice));
    final uPnl = accountUnrealizedPnl();
    available = initialBalance - margin + uPnl;
  }

  /// 删除指定订单并不再计入订单列表。
  ///
  /// Demo 只模拟本地撤单；真实项目需要发送取消请求，并等待服务端确认。
  void cancelOrder(String id) {
    orders.removeWhere((o) => o.id == id);
    notifyListeners();
  }

  /// 使用标记价一次性平掉指定持仓。
  void closePositionAtMarket(int index) {
    final p = positions[index];
    if (p.size == 0) return;
    final side = p.isLong ? OrderSide.sell : OrderSide.buy;
    final updated =
        engine.close(p, closeSide: side, qty: p.absSize, price: markPrice)!;
    positions[index] = updated;
    _recalcAccount();
    notifyListeners();
  }
}
