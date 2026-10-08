// 模块：交易所领域数据模型
// 作用：定义行情、K 线、订单、持仓、账户和订单簿档位等跨模块共享数据结构。
// 设计原则：本文件只包含纯 Dart 类型，不依赖 Flutter，方便核心逻辑测试和复用。

library;

/// 订单方向：buy 表示买入/开多，sell 表示卖出/开空。
enum OrderSide {
  buy,
  sell;

  static OrderSide fromString(String s) =>
      s.toLowerCase() == 'buy' ? OrderSide.buy : OrderSide.sell;
}

/// 订单类型：limit 限价单，market 市价单。
enum OrderType { limit, market }

/// 保证金模式：cross 全仓，isolated 逐仓。
enum MarginMode { cross, isolated }

/// K 线周期。
///
/// [wireValue] 用于 WebSocket 订阅协议，[label] 用于 UI 展示，[duration] 用于模拟
/// 服务端按周期生成时间戳，[historyCount] 表示首次订阅需要补齐多少根历史 K 线。
enum KlineInterval {
  min15('15m', '15分', Duration(minutes: 15), 120),
  hour1('1h', '1时', Duration(hours: 1), 120),
  hour4('4h', '4时', Duration(hours: 4), 120),
  day1('1d', '1日', Duration(days: 1), 120),
  month1('1M', '1月', Duration(days: 30), 120);

  const KlineInterval(
    this.wireValue,
    this.label,
    this.duration,
    this.historyCount,
  );

  final String wireValue;
  final String label;
  final Duration duration;
  final int historyCount;

  /// 把服务端协议值转换为 K 线周期，未知值默认回退到 15 分钟。
  static KlineInterval fromWireValue(String? value) {
    for (final interval in values) {
      if (interval.wireValue == value) return interval;
    }
    return KlineInterval.min15;
  }
}

/// 订单簿单个价格档位。
///
/// [price] 是聚合后的价格，[size] 是该价格档位的剩余数量；size 为 0 时表示删除档位。
class OrderBookLevel {
  OrderBookLevel(this.price, this.size);

  final double price;
  final double size;

  @override
  String toString() => 'Level($price, $size)';
}

/// 实时行情 Ticker。
///
/// 汇总最新成交价、24h 涨跌、最高/最低价和成交量，主要驱动顶部行情栏。
class Ticker {
  Ticker({
    required this.symbol,
    required this.last,
    required this.change24h,
    required this.change24hPercent,
    required this.high24h,
    required this.low24h,
    required this.volume24h,
  });

  final String symbol;
  final double last;
  final double change24h;
  final double change24hPercent;
  final double high24h;
  final double low24h;
  final double volume24h;
}

/// 逐笔成交。
///
/// [side] 是主动买入/卖出方向，[ts] 是服务端时间戳，用于成交列表或成交量统计。
class Trade {
  Trade(
      {required this.side,
      required this.price,
      required this.qty,
      required this.ts});

  final String side; // buy / sell
  final double price;
  final double qty;
  final int ts;
}

/// 单根 K 线。
///
/// 使用 OHLCV 结构描述一段时间窗口；KlinePainter 会根据 open/close 决定红绿颜色，
/// 并用 high/low 绘制上下影线。
class Kline {
  Kline({
    required this.ts,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final int ts;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
}

/// 委托单（下单请求 / 订单状态）。
///
/// 同时承载客户端下单参数和服务端返回的状态；price 为空表示市价单，
/// status 在 Demo 中直接模拟为 FILLED。
class Order {
  Order({
    required this.id,
    required this.symbol,
    required this.side,
    required this.type,
    required this.qty,
    this.price,
    required this.leverage,
    required this.marginMode,
    this.tpPrice,
    this.slPrice,
    this.reduceOnly = false,
    this.status = 'NEW',
  });

  final String id;
  final String symbol;
  final OrderSide side;
  final OrderType type;
  final double qty;
  final double? price; // 市价单为 null
  final double leverage;
  final MarginMode marginMode;
  final double? tpPrice;
  final double? slPrice;
  final bool reduceOnly;
  final String status; // NEW / FILLED / CANCELED
}

/// 持仓（size > 0 多，size < 0 空）。
class Position {
  Position({
    required this.symbol,
    required this.size,
    required this.entryPrice,
    required this.leverage,
    required this.marginMode,
    this.tpPrice,
    this.slPrice,
    this.realizedPnl = 0,
  });

  final String symbol;
  final double size;
  final double entryPrice;
  final double leverage;
  final MarginMode marginMode;
  final double? tpPrice;
  final double? slPrice;
  final double realizedPnl;

  bool get isLong => size > 0;
  double get absSize => size.abs();

  /// 复制并更新持仓字段，保持不可变模型在加减仓后可以安全替换。
  Position copyWith({
    double? size,
    double? entryPrice,
    double? realizedPnl,
    double? tpPrice,
    double? slPrice,
  }) {
    return Position(
      symbol: symbol,
      size: size ?? this.size,
      entryPrice: entryPrice ?? this.entryPrice,
      leverage: leverage,
      marginMode: marginMode,
      tpPrice: tpPrice ?? this.tpPrice,
      slPrice: slPrice ?? this.slPrice,
      realizedPnl: realizedPnl ?? this.realizedPnl,
    );
  }
}

/// 账户资产概览。
///
/// balance 为权益，available 为可用余额，margin 为占用保证金，
/// unrealizedPnl 汇总当前所有持仓的浮动盈亏。
class Account {
  Account({
    required this.balance,
    required this.available,
    required this.margin,
    required this.unrealizedPnl,
  });

  final double balance; // 权益
  final double available; // 可用
  final double margin; // 占用保证金
  final double unrealizedPnl; // 未实现盈亏
}
