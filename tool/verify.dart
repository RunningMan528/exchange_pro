// 模块：纯 Dart 核心链路验证脚本
// 作用：验证订单簿 Sequence、合约计算、批处理、WebSocket 重连和心跳保活。
// 运行方式：在 exchange_flutter_demo 目录执行 `dart tool/verify.dart`。
// 设计目的：核心逻辑不依赖 Flutter，因此可以用轻量脚本快速完成回归检查。

import 'dart:convert';

import '../lib/core/models.dart';
import '../lib/core/order_book_engine.dart';
import '../lib/core/contract_engine.dart';
import '../lib/core/throttle.dart';
import '../lib/core/ws_connection.dart';
import '../lib/core/market_feed.dart';

int _passed = 0;
int _failed = 0;

/// 记录一条断言结果；失败时不会立即退出，便于一次看到完整失败列表。
void expect(bool cond, String name) {
  if (cond) {
    _passed++;
    print('  [PASS] $name');
  } else {
    _failed++;
    print('  [FAIL] $name');
  }
}

/// 把测试数据中的 [price, size] 列表转换为订单簿档位模型。
List<OrderBookLevel> _levels(dynamic raw) {
  return (raw as List)
      .map((e) =>
          OrderBookLevel((e[0] as num).toDouble(), (e[1] as num).toDouble()))
      .toList();
}

/// 验证订单簿的初始化、增量、删除、过期消息和 Sequence 缺口处理。
void _testOrderBook() {
  print('== 订单簿：快照 + 增量 + Sequence ==');
  final engine = OrderBookEngine();

  expect(
      engine.applyDelta(DepthDelta(1, [], [])) == DepthApplyResult.needSnapshot,
      '未收到快照时拒绝增量');

  final r0 = engine.applySnapshot(DepthSnapshot(100, [
    OrderBookLevel(50000, 1.0),
    OrderBookLevel(49900, 2.0),
  ], [
    OrderBookLevel(50100, 3.0),
    OrderBookLevel(50200, 4.0),
  ]));
  expect(r0 == DepthApplyResult.applied, '快照正常应用');
  expect(engine.bestBid == 50000 && engine.bestAsk == 50100, '最优买卖价正确');
  expect((engine.midPrice! - 50050).abs() < 1e-9, '中间价正确');
  expect(engine.spread == 100, '价差正确');

  expect(
      engine.applyDelta(DepthDelta(101, [OrderBookLevel(49950, 5.0)], [])) ==
          DepthApplyResult.applied,
      '连续增量正常应用');
  expect(engine.topBids(1)[0].price == 50000, '买盘 Top-1 正确');

  expect(
      engine.applyDelta(DepthDelta(102, [OrderBookLevel(49900, 0.0)], [])) ==
          DepthApplyResult.applied,
      'size=0 删除档位');
  expect(engine.topBids(5).length == 2, '删除后买盘档位减少');

  expect(
      engine.applyDelta(DepthDelta(102, [OrderBookLevel(1, 1)], [])) ==
          DepthApplyResult.stale,
      '过期消息被丢弃');

  expect(
      engine.applyDelta(DepthDelta(105, [OrderBookLevel(1, 1)], [])) ==
          DepthApplyResult.gap,
      '序号缺口被识别并触发重订阅');
}

/// 验证多空盈亏、同向加仓均价、平仓结算和强平价方向。
void _testContract() {
  print('== 合约：盈亏 / 开平仓合并 / 强平价 ==');
  final engine = ContractEngine();

  final pos = engine.open(null,
      side: OrderSide.buy,
      qty: 1.0,
      price: 60000,
      leverage: 10,
      marginMode: MarginMode.cross);
  expect(
      engine.unrealizedPnl(pos, 61000) == 1000, '多单未实现盈亏 = (mark-entry)*qty');
  expect(engine.unrealizedPnl(pos, 59000) == -1000, '多单亏损计算正确');

  final short = engine.open(null,
      side: OrderSide.sell,
      qty: 1.0,
      price: 60000,
      leverage: 10,
      marginMode: MarginMode.cross);
  expect(
      engine.unrealizedPnl(short, 59000) == 1000, '空单未实现盈亏 = (entry-mark)*qty');

  final merged = engine.open(pos,
      side: OrderSide.buy,
      qty: 1.0,
      price: 62000,
      leverage: 10,
      marginMode: MarginMode.cross);
  expect((merged.entryPrice - 61000).abs() < 1e-9 && merged.size == 2,
      '同向加仓合并平均开仓价');

  final closed =
      engine.close(merged, closeSide: OrderSide.sell, qty: 1.0, price: 63000)!;
  expect(closed.size == 1 && (closed.realizedPnl - 2000).abs() < 1e-9,
      '平仓结算已实现盈亏');

  final liq = engine.liquidationPrice(pos);
  expect(liq > 0 && liq < pos.entryPrice, '多单强平价低于开仓价');
}

/// 验证完整连接链路：快照、增量、缺口重订阅、心跳和断线重连。
Future<void> _testConnection() async {
  print('== WebSocket：快照/增量/缺口/心跳/重连 ==');
  final engine = OrderBookEngine();
  var snapshots = 0;
  var deltas = 0;
  var gaps = 0;
  var reconnects = 0;
  var lastState = WsConnectionState.idle;

  late final MarketConnection conn;
  conn = MarketConnection(
    transportFactory: () => MockMarketFeed(
      gapEvery: 5,
      dropAfter: const Duration(milliseconds: 1200),
      deltaInterval: const Duration(milliseconds: 40),
      tickerInterval: const Duration(milliseconds: 300),
    ),
    heartbeatInterval: const Duration(milliseconds: 250),
    heartbeatTimeout: const Duration(milliseconds: 200),
    reconnectBaseDelay: const Duration(milliseconds: 300),
    reconnectMaxDelay: const Duration(seconds: 1),
  );

  conn.onStateChanged = (s) {
    lastState = s;
    if (s == WsConnectionState.connected) reconnects++;
  };

  conn.onMessage = (data) {
    final m = jsonDecode(data) as Map<String, dynamic>;
    if (m['channel'] != 'depth') return;
    if (m['type'] == 'snapshot') {
      engine.applySnapshot(DepthSnapshot(
          m['seq'] as int, _levels(m['bids']), _levels(m['asks'])));
      snapshots++;
    } else {
      final r = engine.applyDelta(
          DepthDelta(m['seq'] as int, _levels(m['bids']), _levels(m['asks'])));
      if (r == DepthApplyResult.applied) deltas++;
      if (r == DepthApplyResult.gap) {
        gaps++;
        // 检测到缺口 → 主动重订阅 depth，服务端回新快照。
        conn.send(
            '{"op":"subscribe","channels":["depth","ticker","trade","kline"]}');
      }
    }
  };

  conn.onResubscribe = () {
    conn.send(
        '{"op":"subscribe","channels":["depth","ticker","trade","kline"]}');
  };

  conn.connect();
  await Future<void>.delayed(const Duration(milliseconds: 3500));
  conn.close();

  expect(snapshots > 0, '收到深度快照 (snapshot)');
  expect(deltas > 0, '连续应用增量 (delta)');
  expect(gaps > 0, '检测到序号缺口并重订阅');
  expect(snapshots >= 2, '重连/重订阅后重新拿到快照');
  expect(engine.hasSnapshot && engine.bestBid != null && engine.bestAsk != null,
      '本地盘口可用');
  expect(conn.pongCount > 0, '心跳 pong 正常');
  expect(reconnects >= 2, '服务端断线后完成自动重连');
  expect(lastState == WsConnectionState.closed, '主动 close 进入 closed 状态');
}

/// 验证正常 pong 保活时不会误触发重连。
Future<void> _testHeartbeatKeepsAlive() async {
  print('== 心跳保活：无断线时不应触发重连 ==');
  var reconnects = 0;
  final conn = MarketConnection(
    transportFactory: () => MockMarketFeed(
      gapEvery: 100000,
      dropAfter: const Duration(minutes: 10),
      deltaInterval: const Duration(seconds: 10),
    ),
    heartbeatInterval: const Duration(milliseconds: 150),
    heartbeatTimeout: const Duration(milliseconds: 100),
  );
  conn.onStateChanged = (s) {
    if (s == WsConnectionState.connected) reconnects++;
  };
  conn.onResubscribe = () {
    conn.send('{"op":"subscribe","channels":["depth"]}');
  };
  conn.connect();
  await Future<void>.delayed(const Duration(milliseconds: 800));
  conn.close();
  expect(conn.pongCount > 0, '心跳正常收发 pong');
  expect(reconnects == 1, 'pong 保活，未发生超时重连');
}

/// 验证 BatchBuffer 能把窗口内多条消息合并为一次回调。
Future<void> _testBatch() async {
  print('== 批处理：窗口内合并回调 ==');
  var flushed = 0;
  var total = 0;
  final buffer = BatchBuffer<int>(const Duration(milliseconds: 60), (batch) {
    flushed++;
    total += batch.length;
  });
  for (var i = 0; i < 50; i++) {
    buffer.add(i);
  }
  await Future<void>.delayed(const Duration(milliseconds: 120));
  expect(flushed == 1 && total == 50, '50 条消息在窗口内合并为 1 次回调');
  buffer.dispose();
}

/// 按从纯计算到异步连接的顺序执行全部验证，并汇总通过/失败数量。
Future<void> main() async {
  _testOrderBook();
  _testContract();
  await _testBatch();
  await _testConnection();
  await _testHeartbeatKeepsAlive();
  print('');
  print('结果：$_passed 通过，$_failed 失败');
  if (_failed > 0) {
    throw StateError('存在失败用例');
  }
}
