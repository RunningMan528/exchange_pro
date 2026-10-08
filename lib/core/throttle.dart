// 模块：高频数据缓冲工具
// 作用：提供 BatchBuffer，用于把短时间窗口内的多条消息合并为一次批量回调。
// 典型场景：深度增量按较低频率到达，先在 100ms 窗口内合并，再统一应用和刷新。
// 资源管理：dispose() 会取消防抖定时器，避免页面销毁后仍触发回调。

import 'dart:async';

/// 批量缓冲器：同一个窗口内的数据会被合并成一次回调。
///
/// 适合订单簿增量这类“可以批量处理、但不能丢消息”的场景。第一批数据到达时
/// 启动定时器，窗口到期后复制整个批次交给 [onFlush]，从而把多次状态更新合并。
class BatchBuffer<T> {
  BatchBuffer(this.interval, this.onFlush);

  final Duration interval;
  final void Function(List<T> batch) onFlush;

  final List<T> _pending = <T>[];
  Timer? _timer;

  bool get isEmpty => _pending.isEmpty;
  int get length => _pending.length;

  /// 追加一条数据；首个元素到达时启动定时器。
  void add(T item) {
    _pending.add(item);
    _timer ??= Timer(interval, _flush);
  }

  /// 定时窗口到期后复制并清空缓冲区，再统一交给 [onFlush]。
  ///
  /// 先复制再回调可以避免回调期间新增的数据被误清空。
  void _flush() {
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = List<T>.from(_pending);
    _pending.clear();
    onFlush(batch);
  }

  /// 立即刷新当前缓冲内容，并取消尚未触发的定时器。
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    _flush();
  }

  /// 丢弃未处理数据（例如收到权威快照时清空旧增量）。
  /// 丢弃尚未处理的增量。
  ///
  /// 收到权威深度快照时调用，避免旧增量覆盖新快照。
  void clear() {
    _pending.clear();
  }

  /// 取消定时器并释放待处理数据，页面销毁时必须调用。
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}

/// 节流：固定周期内只放行一次回调，丢弃中间高频触发。
/// 常用于 ticker 价格这类“只关心最新值”的场景。
/// 节流器：固定周期内只执行一次回调，中间触发会被合并。
///
/// 适合只关心最新值的场景，例如 Ticker 文案刷新；不保证每一条消息都被处理。
class Throttler {
  Throttler(this.interval, this.onTick);

  final Duration interval;
  final void Function() onTick;

  Timer? _timer;
  bool _pending = false;

  /// 触发一次节流更新。
  ///
  /// 如果当前周期仍在计时，只记录 pending；计时结束后再执行一次最新回调。
  void trigger() {
    if (_timer != null) {
      _pending = true;
      return;
    }
    _timer = Timer(interval, () {
      _timer = null;
      onTick();
      if (_pending) {
        _pending = false;
        trigger();
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = false;
  }
}
