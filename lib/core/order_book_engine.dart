// 模块：本地订单簿引擎
// 作用：维护买卖盘，实现 Snapshot + Incremental Update、Sequence 校验和价格聚合。
// 数据流：快照重建全量盘口；增量按 seq 连续性应用到 SplayTreeMap；缺口返回 gap。
// 对应模板：高流动性交易所客户端中的 Top-N 深度盘口与低延迟本地账本。

import 'dart:collection';
import 'models.dart';

/// 订单簿增量处理结果。
enum DepthApplyResult {
  /// 正常应用。
  applied,

  /// 消息序号 <= 当前序号，属于过期/重复消息，直接丢弃。
  stale,

  /// 序号不连续，存在缺口，需要重新订阅快照。
  gap,

  /// 尚未收到快照，无法应用增量。
  needSnapshot,
}

/// 订单簿权威快照。
///
/// 快照包含某个 seq 下的完整买卖盘，客户端收到后必须清空旧盘口并整体替换。
class DepthSnapshot {
  DepthSnapshot(this.seq, this.bids, this.asks);

  final int seq;
  final List<OrderBookLevel> bids;
  final List<OrderBookLevel> asks;
}

/// 订单簿增量消息。
///
/// 只携带发生变化的档位；某个价格 size 为 0 表示该档位已被删除。
class DepthDelta {
  DepthDelta(this.seq, this.bids, this.asks);

  final int seq;
  final List<OrderBookLevel> bids;
  final List<OrderBookLevel> asks;
}

/// 订单簿引擎：维护本地买卖盘，实现
/// Snapshot + Incremental Update 合并与 Sequence 校验。
///
/// 核心思想：
/// - 服务端为每条深度消息分配单调递增的 seq；
/// - 先推 [DepthSnapshot]，后续推 [DepthDelta]；
/// - 客户端用 lastSeq 判断连续性，出现缺口立刻触发重订阅，
///   避免本地盘口与交易所产生静默偏差。
class OrderBookEngine {
  // 买盘降序：价格越高越靠前；卖盘升序：价格越低越靠前。
  final SplayTreeMap<double, double> _bids =
      SplayTreeMap<double, double>((a, b) => b.compareTo(a));
  final SplayTreeMap<double, double> _asks =
      SplayTreeMap<double, double>((a, b) => a.compareTo(b));

  int? _lastSeq;

  int? get lastSeq => _lastSeq;
  bool get hasSnapshot => _lastSeq != null;

  double? get bestBid => _bids.keys.isEmpty ? null : _bids.keys.first;
  double? get bestAsk => _asks.keys.isEmpty ? null : _asks.keys.first;

  double? get midPrice {
    final b = bestBid;
    final a = bestAsk;
    if (b == null || a == null) return null;
    return (b + a) / 2;
  }

  double get spread {
    final b = bestBid;
    final a = bestAsk;
    if (b == null || a == null) return 0;
    return a - b;
  }

  /// 应用权威快照并重建本地买卖盘。
  ///
  /// 快照会覆盖当前所有数据，同时把 [_lastSeq] 推进到 snapshot.seq，
  /// 后续增量必须从这个序号继续追加。
  DepthApplyResult applySnapshot(DepthSnapshot snapshot) {
    _bids.clear();
    _asks.clear();
    for (final l in snapshot.bids) {
      if (l.size > 0) _bids[l.price] = l.size;
    }
    for (final l in snapshot.asks) {
      if (l.size > 0) _asks[l.price] = l.size;
    }
    _lastSeq = snapshot.seq;
    return DepthApplyResult.applied;
  }

  /// 校验并应用增量消息。
  ///
  /// 返回 [DepthApplyResult.stale] 表示重复/过期，返回 gap 表示需要重新订阅
  /// 深度快照；只有连续序号才会真正修改本地订单簿。
  DepthApplyResult applyDelta(DepthDelta delta) {
    final last = _lastSeq;
    if (last == null) return DepthApplyResult.needSnapshot;

    if (delta.seq <= last) return DepthApplyResult.stale;
    if (delta.seq > last + 1) return DepthApplyResult.gap;

    _mergeSide(_bids, delta.bids);
    _mergeSide(_asks, delta.asks);
    _lastSeq = delta.seq;
    return DepthApplyResult.applied;
  }

  /// 按档位合并一侧订单簿；size > 0 做 upsert，size <= 0 删除价格档。
  void _mergeSide(
      SplayTreeMap<double, double> side, List<OrderBookLevel> levels) {
    for (final l in levels) {
      if (l.size <= 0) {
        side.remove(l.price); // size = 0 → 删除档位
      } else {
        side[l.price] = l.size; // upsert
      }
    }
  }

  /// 获取价格最优的前 N 档买盘，结果按价格从高到低排列。
  List<OrderBookLevel> topBids(int n) =>
      _bids.entries.take(n).map((e) => OrderBookLevel(e.key, e.value)).toList();

  /// 获取价格最优的前 N 档卖盘，结果按价格从低到高排列。
  List<OrderBookLevel> topAsks(int n) =>
      _asks.entries.take(n).map((e) => OrderBookLevel(e.key, e.value)).toList();

  /// 按 tickSize 向下聚合买盘价格，并返回聚合后的 Top-N。
  ///
  /// 买盘使用 floor，确保聚合后的价格不会高于原始可成交买价。
  List<OrderBookLevel> aggregatedTopBids(int n, double tickSize) {
    final levels = <double, double>{};
    for (final e in _bids.entries) {
      final bucket = (e.key / tickSize).floor() * tickSize;
      levels[bucket] = (levels[bucket] ?? 0) + e.value;
    }
    final sorted = levels.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return sorted.take(n).map((e) => OrderBookLevel(e.key, e.value)).toList();
  }

  /// 按 tickSize 向上聚合卖盘价格，并返回聚合后的 Top-N。
  ///
  /// 卖盘使用 ceil 是为了让同一价格 bucket 的边界始终落在可交易价格上。
  List<OrderBookLevel> aggregatedTopAsks(int n, double tickSize) {
    final levels = <double, double>{};
    for (final e in _asks.entries) {
      final bucket = (e.key / tickSize).ceil() * tickSize;
      levels[bucket] = (levels[bucket] ?? 0) + e.value;
    }
    final sorted = levels.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sorted.take(n).map((e) => OrderBookLevel(e.key, e.value)).toList();
  }
}
