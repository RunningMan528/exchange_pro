// 模块：模拟交易所行情服务端
// 作用：实现 Transport，在无网络环境中推送 Depth/Ticker/Trade/Kline 消息。
// 行为：支持快照、增量、Sequence 缺口、心跳 pong、定期断线和多周期 K 线历史数据。
// 用途：让 Demo 可以完整演示订阅、断线重连、重订阅和订单簿恢复流程。

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'ws_connection.dart';

/// 模拟交易所行情服务端。
///
/// 实现 [Transport]，用于在没有真实 WebSocket 服务的情况下演示：
/// - 深度快照 + 增量 + Sequence 缺口；
/// - Ticker / Trade / Kline 多频道；
/// - 心跳 pong 与断线重连。
class MockMarketFeed implements Transport {
  MockMarketFeed({
    this.symbol = 'BTC-USDT',
    this.depthLevels = 40,
    this.deltaInterval = const Duration(milliseconds: 180),
    this.klineInterval = const Duration(milliseconds: 650),
    this.tickerInterval = const Duration(seconds: 1),
    this.gapEvery = 25,
    this.dropAfter = const Duration(seconds: 12),
    int seed = 7,
  }) : _random = Random(seed);

  final String symbol;
  final int depthLevels;
  final Duration deltaInterval;
  final Duration klineInterval;
  final Duration tickerInterval;

  /// 每 gapEvery 条增量制造一次 seq 缺口，验证客户端重订阅逻辑。
  final int gapEvery;

  /// 模拟服务端主动断线，验证客户端重连。
  final Duration dropAfter;

  final Random _random;

  @override
  void Function()? onOpen;
  @override
  void Function(String data)? onMessage;
  @override
  void Function(Object error)? onError;
  @override
  void Function()? onClose;

  final Set<String> _subscribed = <String>{};
  final List<double> _askPrices = [];
  final List<double> _bidPrices = [];

  int _seq = 0;
  int _deltaCount = 0;
  double _lastPrice = 60000;
  int _tradeTs = 0;
  KlineInterval _klineInterval = KlineInterval.min15;
  int _currentKlineTs = 0;
  int _currentKlineTicks = 0;
  double _currentKlineOpen = 60000;
  double _currentKlineHigh = 60000;
  double _currentKlineLow = 60000;
  Timer? _deltaTimer;
  Timer? _klineTimer;
  Timer? _tickerTimer;
  Timer? _dropTimer;

  /// 模拟建立连接：初始化盘口，延迟触发 onOpen，并安排一次服务端断线。
  ///
  /// 80ms 的延迟用于模拟网络握手；连接建立后由 MarketConnection 发送订阅消息。
  @override
  void connect() {
    _seq = 100;
    _deltaCount = 0;
    _initBook();
    // 模拟网络握手。
    Future.delayed(const Duration(milliseconds: 80), () {
      onOpen?.call();
    });
    _dropTimer?.cancel();
    // 模拟服务端在 dropAfter 后主动断线。
    _dropTimer = Timer(dropAfter, () {
      _stopTimers();
      onClose?.call();
    });
  }

  /// 根据当前模拟价格初始化买卖盘价格梯度。
  void _initBook() {
    _askPrices.clear();
    _bidPrices.clear();
    for (var i = 0; i < depthLevels; i++) {
      _askPrices.add(_lastPrice + (i + 1) * 10);
      _bidPrices.add(_lastPrice - (i + 1) * 10);
    }
  }

  /// 接收客户端操作并模拟服务端响应。
  ///
  /// ping 返回 pong；subscribe 根据频道推送快照或启动对应定时器；
  /// unsubscribe 从订阅集合中移除频道。
  @override
  void send(String data) {
    final msg = jsonDecode(data) as Map<String, dynamic>;
    final op = msg['op'] as String?;
    if (op == 'ping') {
      onMessage?.call('pong');
      return;
    }
    if (op == 'subscribe') {
      final channels = (msg['channels'] as List).cast<String>();
      final needDepth = channels.contains('depth');
      _subscribed.addAll(channels);
      if (needDepth) _sendSnapshot(); // 每次订阅 depth 都回一张快照。
      if (channels.contains('kline')) {
        // 切换周期时重新下发该周期的历史数据，客户端清空旧图后直接重建。
        _klineInterval =
            KlineInterval.fromWireValue(msg['interval'] as String?);
        _sendKlineHistory();
      }
      _startDeltaTimer();
      _startKlineTimer();
      _startTickerTimer();
      return;
    }
    if (op == 'unsubscribe') {
      _subscribed.removeAll((msg['channels'] as List).cast<String>());
    }
  }

  /// 生成并推送一份完整深度快照。
  ///
  /// 每次重新订阅 depth 都会生成新快照和新的 seq，模拟交易所的重新同步流程。
  void _sendSnapshot() {
    _seq += 1;
    final bids = <List<double>>[];
    final asks = <List<double>>[];
    for (var i = 0; i < depthLevels; i++) {
      bids.add([_bidPrices[i], _size()]);
      asks.add([_askPrices[i], _size()]);
    }
    onMessage?.call(jsonEncode({
      'channel': 'depth',
      'type': 'snapshot',
      'seq': _seq,
      'bids': bids,
      'asks': asks,
    }));
  }

  /// 生成并推送深度增量。
  ///
  /// 每隔 gapEvery 条人为跳过 seq，用来验证客户端的 gap 检测和重订阅逻辑。
  void _sendDelta() {
    _deltaCount++;
    // 人为制造 seq 缺口：跳过一个序号，让客户端检测到 gap 并重订阅。
    final isGap = _deltaCount % gapEvery == 0;
    _seq += isGap ? 2 : 1;

    // 随机改 1~3 个档位。
    final bids = <List<double>>[];
    final asks = <List<double>>[];
    final changes = 1 + _random.nextInt(3);
    for (var i = 0; i < changes; i++) {
      if (_random.nextBool()) {
        final idx = _random.nextInt(depthLevels);
        _askPrices[idx] += (_random.nextDouble() - 0.5) * 4;
        asks.add([_askPrices[idx], _size()]);
      } else {
        final idx = _random.nextInt(depthLevels);
        _bidPrices[idx] += (_random.nextDouble() - 0.5) * 4;
        bids.add([_bidPrices[idx], _size()]);
      }
    }
    onMessage?.call(jsonEncode({
      'channel': 'depth',
      'type': 'delta',
      'seq': _seq,
      'bids': bids,
      'asks': asks,
    }));
  }

  /// 启动深度/成交定时器。
  ///
  /// 深度和逐笔成交保持相对较快的节奏，但不再与 K 线共用同一个定时器。
  void _startDeltaTimer() {
    _deltaTimer?.cancel();
    _deltaTimer = Timer.periodic(deltaInterval, (_) {
      if (_subscribed.contains('depth')) _sendDelta();
      if (_subscribed.contains('trade')) _sendTrade();
    });
  }

  /// 启动 K 线专用定时器。
  ///
  /// K 线频率低于盘口和成交，避免价格走势在每个深度周期都发生视觉抖动。
  void _startKlineTimer() {
    _klineTimer?.cancel();
    _klineTimer = Timer.periodic(klineInterval, (_) {
      if (_subscribed.contains('kline')) _sendKline();
    });
  }

  /// 启动低频 Ticker 定时器，定期刷新最新价和 24h 指标。
  void _startTickerTimer() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(tickerInterval, (_) {
      if (_subscribed.contains('ticker')) _sendTicker();
    });
  }

  /// 生成一条随机买卖方向的逐笔成交。
  void _sendTrade() {
    _tradeTs++;
    _lastPrice += (_random.nextDouble() - 0.5) * 40;
    onMessage?.call(jsonEncode({
      'channel': 'trade',
      'data': {
        'side': _random.nextBool() ? 'buy' : 'sell',
        'price': _lastPrice,
        'qty': (1 + _random.nextInt(10)) * 0.01,
        'ts': _tradeTs,
      },
    }));
  }

  /// 生成一条 Ticker 消息，包含最新价、涨跌幅和 24h 高低点。
  void _sendTicker() {
    final change = _random.nextDouble() * 2000 - 1000;
    onMessage?.call(jsonEncode({
      'channel': 'ticker',
      'data': {
        'symbol': symbol,
        'last': _lastPrice,
        'change24h': change,
        'change24hPercent': change / _lastPrice * 100,
        'high24h': _lastPrice + 800,
        'low24h': _lastPrice - 800,
        'volume24h': 12000 + _random.nextDouble() * 5000,
      },
    }));
  }

  /// 订阅 K 线或切换周期时补发一段历史数据。
  ///
  /// 使用随机游走生成合法的 open/high/low/close，确保图表启动或切换周期后立即有
  /// 蜡烛形状，而不是等待实时消息逐根累积。
  void _sendKlineHistory() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stepMs = _klineInterval.duration.inMilliseconds;
    var price = _lastPrice - 500 + _random.nextDouble() * 1000;
    var lastHigh = price;
    var lastLow = price;

    for (var i = _klineInterval.historyCount - 1; i >= 0; i--) {
      final open = price;
      final close = open + (_random.nextDouble() - 0.48) * 180;
      final high = max(open, close) + _random.nextDouble() * 70;
      final low = min(open, close) - _random.nextDouble() * 70;
      lastHigh = high;
      lastLow = low;
      onMessage?.call(jsonEncode({
        'channel': 'kline',
        'data': {
          'ts': now - i * stepMs,
          'open': open,
          'high': high,
          'low': low,
          'close': close,
          'volume': 0.6 + _random.nextDouble() * 2.4,
        },
      }));
      price = close;
    }

    _lastPrice = price;
    _beginCurrentKline(price, ts: now, high: lastHigh, low: lastLow);
  }

  /// 开始一根新的当前 K 线。
  ///
  /// 真正交易所只在周期结束时追加新蜡烛；Demo 用固定 tick 数模拟这个边界。
  void _beginCurrentKline(
    double price, {
    int? ts,
    double? high,
    double? low,
  }) {
    _currentKlineTs = ts ?? DateTime.now().millisecondsSinceEpoch;
    _currentKlineTicks = 0;
    _currentKlineOpen = price;
    _currentKlineHigh = high ?? price;
    _currentKlineLow = low ?? price;
  }

  /// 生成当前周期的实时 K 线。
  ///
  /// 大多数更新只修改同一时间戳的当前蜡烛，只有达到周期切换条件时才追加新蜡烛。
  /// 这样图表不会因每 650ms 的消息持续自动滚动。
  void _sendKline() {
    if (_currentKlineTs == 0) _beginCurrentKline(_lastPrice);
    if (_currentKlineTicks >= 12) _beginCurrentKline(_lastPrice);

    _lastPrice += (_random.nextDouble() - 0.5) * 36;
    final close = _lastPrice;
    _currentKlineHigh = max(_currentKlineHigh, close);
    _currentKlineLow = min(_currentKlineLow, close);
    _currentKlineTicks++;

    onMessage?.call(jsonEncode({
      'channel': 'kline',
      'data': {
        'ts': _currentKlineTs,
        'open': _currentKlineOpen,
        'high': _currentKlineHigh,
        'low': _currentKlineLow,
        'close': close,
        'volume': 0.1 + _random.nextDouble() * 0.8,
      },
    }));
  }

  /// 生成 0.01~0.50 的随机订单簿数量。
  double _size() => (1 + _random.nextInt(50)) * 0.01;

  /// 停止所有行情定时器，用于断线或主动关闭连接。
  void _stopTimers() {
    _deltaTimer?.cancel();
    _klineTimer?.cancel();
    _tickerTimer?.cancel();
  }

  /// 关闭模拟服务，取消行情和断线定时器。
  @override
  void close() {
    _stopTimers();
    _dropTimer?.cancel();
  }
}
