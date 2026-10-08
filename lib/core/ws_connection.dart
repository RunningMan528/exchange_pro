// 模块：WebSocket 连接生命周期管理
// 作用：抽象底层 Transport，并统一处理连接状态、心跳、pong 超时、断线重连和订阅恢复。
// 重连策略：指数退避加随机抖动，避免服务端故障恢复时大量客户端同时重连。
// 业务回调：onMessage 处理行情，onResubscribe 在每次连接成功后恢复频道订阅。

import 'dart:async';
import 'dart:math';

/// WebSocket 连接状态机。
///
/// idle 表示未启动，connecting/connected 表示建连阶段，
/// reconnecting 表示已断开并在退避重试，closed 表示用户主动关闭。
enum WsConnectionState { idle, connecting, connected, reconnecting, closed }

/// 底层传输抽象。
///
/// 管理层只依赖这组 connect/send/close 和事件回调，因此生产环境可以接入真正的
/// WebSocket 客户端，测试和 Demo 则可以替换成 MockMarketFeed。
abstract class Transport {
  void connect();
  void send(String data);
  void close();

  void Function()? onOpen;
  void Function(String data)? onMessage;
  void Function(Object error)? onError;
  void Function()? onClose;
}

/// 行情 WebSocket 连接管理器。
///
/// 它把“连接生命周期”和“业务订阅”解耦：底层 transportFactory 负责具体网络，
/// 本类负责连接状态、心跳、pong 超时、指数退避重连和重连后的频道恢复。
/// 连接建立后通过 onResubscribe 通知业务层重新订阅并拉取权威快照。
class MarketConnection {
  MarketConnection({
    required Transport Function() transportFactory,
    this.heartbeatInterval = const Duration(seconds: 5),
    this.heartbeatTimeout = const Duration(seconds: 3),
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 30),
    this.pingText = '{"op":"ping"}',
    this.pongText = 'pong',
  }) : _transportFactory = transportFactory;

  final Transport Function() _transportFactory;
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;
  final String pingText;
  final String pongText;

  final Random _random = Random();

  WsConnectionState state = WsConnectionState.idle;
  int reconnectAttempts = 0;

  /// 收到的 pong 次数（用于观测心跳是否正常）。
  int pongCount = 0;

  /// 收到 open / close / error / 重连完成 等事件时回调（供 UI 显示状态）。
  void Function(WsConnectionState state)? onStateChanged;
  void Function(String data)? onMessage;
  void Function()? onResubscribe;

  Transport? _transport;
  Timer? _heartbeatTimer;
  Timer? _pongTimeoutTimer;
  Timer? _reconnectTimer;
  bool _closedByUser = false;

  /// 发起连接；重复调用时不会创建第二个连接。
  ///
  /// 如果上一次是用户主动关闭，这里会重置关闭标记，允许重新连接。
  void connect() {
    if (state == WsConnectionState.connecting ||
        state == WsConnectionState.connected) {
      return;
    }
    _closedByUser = false;
    _openTransport();
  }

  /// 创建并绑定一次底层连接。
  ///
  /// 这是连接生命周期的核心入口：连接成功后启动心跳并调用 onResubscribe，
  /// 遇到 error/close 时统一交给 [_scheduleReconnect] 处理。
  void _openTransport() {
    _setState(WsConnectionState.connecting);
    final transport = _transportFactory();
    _transport = transport;

    transport.onOpen = () {
      if (_closedByUser) return;
      _setState(WsConnectionState.connected);
      reconnectAttempts = 0;
      _startHeartbeat();
      // 连接（或重连）成功后，恢复订阅 / 重新拉取快照。
      onResubscribe?.call();
    };

    transport.onMessage = (data) {
      // 心跳回包：收到 pong 取消超时判定。
      if (data.contains(pongText) || data == 'pong') {
        pongCount++;
        _pongTimeoutTimer?.cancel();
        return;
      }
      onMessage?.call(data);
    };

    transport.onError = (err) {
      if (_closedByUser) return;
      _scheduleReconnect();
    };

    transport.onClose = () {
      if (_closedByUser) return;
      _scheduleReconnect();
    };

    transport.connect();
  }

  /// 启动心跳保活。
  ///
  /// 每隔 heartbeatInterval 发送 ping，并等待 pong；超过 heartbeatTimeout
  /// 仍未收到回包时认为连接假死，主动进入重连流程。
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _pongTimeoutTimer?.cancel();

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      _send(pingText);
      _pongTimeoutTimer?.cancel();
      _pongTimeoutTimer = Timer(heartbeatTimeout, () {
        // 服务端长时间不回 pong，判定连接假死，强制重连。
        _scheduleReconnect();
      });
    });
  }

  /// 对外发送一条业务消息；未连接时静默丢弃，避免 UI 感知底层异常。
  void send(String data) => _send(data);

  void _send(String data) {
    if (state == WsConnectionState.connected) {
      _transport?.send(data);
    }
  }

  /// 安排下一次重连。
  ///
  /// 使用指数退避避免服务端刚恢复时被大量客户端同时打满，并叠加随机抖动
  /// 分散重连时刻；重连成功后由 [_openTransport] 重新执行订阅恢复。
  void _scheduleReconnect() {
    if (_closedByUser) return;
    _heartbeatTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();

    if (state != WsConnectionState.reconnecting) {
      reconnectAttempts = 1;
      _setState(WsConnectionState.reconnecting);
    } else {
      reconnectAttempts++;
    }

    // 指数退避：base * 2^(n-1)，上限 maxDelay，再加抖动避免“惊群”。
    final expMs = reconnectBaseDelay.inMilliseconds *
        pow(2, reconnectAttempts - 1).toInt();
    final delayMs =
        min(expMs, reconnectMaxDelay.inMilliseconds) + _random.nextInt(300);
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), _openTransport);
  }

  /// 用户主动关闭连接并取消所有定时器。
  ///
  /// 关闭后不会再触发自动重连；适用于页面 dispose 或用户退出行情页面。
  void close() {
    _closedByUser = true;
    _heartbeatTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
    _transport?.close();
    _setState(WsConnectionState.closed);
  }

  /// 更新连接状态并通知上层 UI。
  void _setState(WsConnectionState next) {
    state = next;
    onStateChanged?.call(next);
  }
}
