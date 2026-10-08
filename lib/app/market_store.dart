// 模块：行情状态仓库
// 作用：接收 WebSocket 消息，维护 Ticker、Trade、Kline、订单簿和连接状态。
// 数据流：MarketConnection -> _onMessage -> 订单簿引擎/ValueNotifier -> UI。
// 性能策略：深度增量批处理，订单簿、Ticker、K 线各自独立通知，避免整页高频 rebuild。
// 对应模板：实时行情多频道订阅、Snapshot + Incremental Update、断线恢复后的重新订阅。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/market_feed.dart';
import '../core/models.dart';
import '../core/order_book_engine.dart';
import '../core/throttle.dart';
import '../core/ws_connection.dart';

/// 行情状态中心。
///
/// 负责把底层 JSON 消息分发给订单簿、Ticker、Trade 和 Kline，并通过不同的通知
/// 粒度驱动页面局部更新。它是 UI 与行情协议之间的唯一适配层。
class MarketStore extends ChangeNotifier {
  MarketStore({this.deltaBatchWindow = const Duration(milliseconds: 100)});

  final Duration deltaBatchWindow;

  final OrderBookEngine book = OrderBookEngine();
  final List<Trade> trades = [];
  final List<Kline> klines = [];

  /// 订单簿版本号：每次真正应用增量后 +1，供 CustomPainter.shouldRepaint 使用。
  final ValueNotifier<int> bookVersion = ValueNotifier<int>(0);

  /// Ticker 独立通知，只刷新顶栏。
  final ValueNotifier<Ticker?> tickerNotifier = ValueNotifier<Ticker?>(null);

  /// K 线独立版本号，避免和逐笔成交、盘口等高频状态相互触发重建。
  final ValueNotifier<int> klineVersion = ValueNotifier<int>(0);

  /// 当前 K 线周期，UI 修改后由 MarketStore 向服务端重新订阅对应历史数据。
  final ValueNotifier<KlineInterval> klineIntervalNotifier =
      ValueNotifier<KlineInterval>(KlineInterval.min15);

  WsConnectionState connState = WsConnectionState.idle;
  int pongCount = 0;

  /// 深度聚合 tick 与展示档位（演示聚合盘口）。
  double tickSize = 0.5;
  int depthCount = 20;

  late final MarketConnection _conn;
  late final BatchBuffer<DepthDelta> _depthBuffer;

  /// 创建模拟连接、注册回调并启动行情订阅。
  ///
  /// 深度增量先进入 [BatchBuffer]，100ms 后统一应用；连接状态、订单簿版本、
  /// Ticker 和 K 线分别拥有独立刷新通道，避免一条消息触发整页重建。
  void start() {
    _conn = MarketConnection(
      transportFactory: () => MockMarketFeed(
        gapEvery: 30,
        dropAfter: const Duration(seconds: 15),
        deltaInterval: const Duration(milliseconds: 180),
        klineInterval: const Duration(milliseconds: 650),
        tickerInterval: const Duration(milliseconds: 900),
      ),
      heartbeatInterval: const Duration(seconds: 5),
      heartbeatTimeout: const Duration(seconds: 3),
    );
    _conn.onStateChanged = (s) {
      connState = s;
      notifyListeners();
    };
    _conn.onResubscribe = _subscribeAll;
    _conn.onMessage = _onMessage;

    // 深度增量约 180ms 一条，批量窗口仍然保留，保证高频场景下不会逐条刷新。
    _depthBuffer = BatchBuffer<DepthDelta>(deltaBatchWindow, (batch) {
      var changed = false;
      for (final d in batch) {
        final r = book.applyDelta(d);
        if (r == DepthApplyResult.applied) changed = true;
        if (r == DepthApplyResult.gap) {
          // 序号缺口 → 主动重订阅，让服务端重新推快照。
          _resubscribeDepth();
        }
      }
      if (changed) bookVersion.value++;
    });

    _conn.connect();
  }

  /// 订阅 Ticker、成交、K 线和深度四类频道。
  ///
  /// 初次连接和重连成功后都会调用，后者实现模板中要求的“订阅恢复”。
  void _subscribeAll() {
    _conn.send(jsonEncode({
      'op': 'subscribe',
      'channels': ['depth', 'ticker', 'trade', 'kline'],
      'interval': klineIntervalNotifier.value.wireValue,
    }));
  }

  /// 切换 K 线周期并重新拉取该周期的历史数据。
  ///
  /// 切换前先清空旧周期 K 线，避免 15 分钟和 1 小时数据混在同一张图中；
  /// 新周期数据到达后，图表刷新逻辑会把视窗定位到最新一段。
  void changeKlineInterval(KlineInterval interval) {
    if (klineIntervalNotifier.value == interval) return;

    klineIntervalNotifier.value = interval;
    klines.clear();
    klineVersion.value++;
    _conn.send(jsonEncode({
      'op': 'subscribe',
      'channels': ['kline'],
      'interval': interval.wireValue,
    }));
  }

  /// 只重新订阅深度频道，用于 Sequence 缺口后重新获取权威快照。
  void _resubscribeDepth() {
    _conn.send(jsonEncode({
      'op': 'subscribe',
      'channels': ['depth']
    }));
  }

  /// 解析服务端消息并按 channel 分发。
  ///
  /// 深度消息进入订单簿流程，Ticker/Kline 使用独立 ValueNotifier，
  /// Trade 缓存最近 60 条，避免高频行情影响其他 UI 区域。
  void _onMessage(String data) {
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['channel']) {
      case 'depth':
        _onDepth(m);
        break;
      case 'ticker':
        tickerNotifier.value = _parseTicker(m['data'] as Map<String, dynamic>);
        break;
      case 'trade':
        trades.insert(0, _parseTrade(m['data'] as Map<String, dynamic>));
        if (trades.length > 60) trades.removeRange(60, trades.length);
        break;
      case 'kline':
        final kline = _parseKline(m['data'] as Map<String, dynamic>);
        if (klines.isNotEmpty && klines.last.ts == kline.ts) {
          // 当前周期尚未结束，只更新最后一根蜡烛，不制造新的滚动数据。
          klines[klines.length - 1] = kline;
        } else {
          klines.add(kline);
          if (klines.length > 120) klines.removeAt(0);
        }
        klineVersion.value++;
        break;
    }
  }

  /// 处理深度快照或增量。
  ///
  /// 快照会清空批量缓冲并直接重建；增量则先入队批处理，检测到 seq 缺口时
  /// 立即请求新的深度快照。
  void _onDepth(Map<String, dynamic> m) {
    if (m['type'] == 'snapshot') {
      // 权威快照：清空旧增量并立即重建盘口。
      _depthBuffer.clear();
      book.applySnapshot(DepthSnapshot(
        m['seq'] as int,
        _levels(m['bids']),
        _levels(m['asks']),
      ));
      bookVersion.value++;
    } else {
      _depthBuffer.add(DepthDelta(
        m['seq'] as int,
        _levels(m['bids']),
        _levels(m['asks']),
      ));
    }
  }

  /// 把服务端 Ticker JSON 转换为强类型领域模型。
  Ticker _parseTicker(Map<String, dynamic> d) {
    return Ticker(
      symbol: d['symbol'] as String,
      last: (d['last'] as num).toDouble(),
      change24h: (d['change24h'] as num).toDouble(),
      change24hPercent: (d['change24hPercent'] as num).toDouble(),
      high24h: (d['high24h'] as num).toDouble(),
      low24h: (d['low24h'] as num).toDouble(),
      volume24h: (d['volume24h'] as num).toDouble(),
    );
  }

  /// 把服务端逐笔成交 JSON 转换为领域模型。
  Trade _parseTrade(Map<String, dynamic> d) {
    return Trade(
      side: d['side'] as String,
      price: (d['price'] as num).toDouble(),
      qty: (d['qty'] as num).toDouble(),
      ts: d['ts'] as int,
    );
  }

  /// 把服务端 K 线 JSON 转换为 OHLCV 模型。
  Kline _parseKline(Map<String, dynamic> d) {
    return Kline(
      ts: d['ts'] as int,
      open: (d['open'] as num).toDouble(),
      high: (d['high'] as num).toDouble(),
      low: (d['low'] as num).toDouble(),
      close: (d['close'] as num).toDouble(),
      volume: (d['volume'] as num).toDouble(),
    );
  }

  /// 把 [[price, size], ...] 形式的深度数据解析成订单簿档位列表。
  List<OrderBookLevel> _levels(dynamic raw) {
    return (raw as List)
        .map((e) =>
            OrderBookLevel((e[0] as num).toDouble(), (e[1] as num).toDouble()))
        .toList();
  }

  /// 关闭连接、刷新并释放所有通知器。
  @override
  void dispose() {
    _conn.close();
    _depthBuffer.dispose();
    bookVersion.dispose();
    tickerNotifier.dispose();
    klineVersion.dispose();
    klineIntervalNotifier.dispose();
    super.dispose();
  }
}
