// 模块：交易所单页工作台
// 作用：组织行情栏、K 线、订单簿、下单、持仓、订单和连接状态 UI。
// 布局：宽度 >= 900 时使用桌面双栏布局，窄屏自动切换为纵向滚动布局。
// 数据来源：MarketStore 提供行情与订单簿，TradeStore 提供订单、持仓和账户状态。
// 交互原则：Widget 只负责展示和收集输入，下单、平仓等业务逻辑统一交给 Store。
// 对应模板：Bitunix 交易所 Flutter 项目中的实时行情、深度订单簿和 USDT-M 合约交易页面。

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/ws_connection.dart';
import 'kline_painter.dart';
import 'market_store.dart';
import 'order_book_painter.dart';
import 'trade_store.dart';

/// 交易所工作台页面。
///
/// 页面本身只负责组织 UI 和持有两个 Store；实时数据、订单簿计算、持仓盈亏等
/// 状态都存放在 [MarketStore] / [TradeStore] 中，避免 Widget 变成业务状态容器。
class ExchangeScreen extends StatefulWidget {
  const ExchangeScreen({super.key});

  @override
  State<ExchangeScreen> createState() => _ExchangeScreenState();
}

/// 工作台状态对象：负责创建控制器、连接行情、处理响应式布局和释放资源。
class _ExchangeScreenState extends State<ExchangeScreen> {
  final MarketStore market = MarketStore();
  final TradeStore trade = TradeStore();

  late final TextEditingController _qtyCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _tpCtrl;
  late final TextEditingController _slCtrl;

  /// 初始化交易输入控制器，并把行情最新价同步给合约标记价。
  ///
  /// 监听 Ticker 后，持仓未实现盈亏、强平参考和市价成交都会随最新行情更新。
  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: trade.qty.toString());
    _priceCtrl = TextEditingController(text: trade.price.toString());
    _tpCtrl = TextEditingController();
    _slCtrl = TextEditingController();

    // 行情最新价 → 合约标记价。
    market.tickerNotifier.addListener(() {
      final t = market.tickerNotifier.value;
      if (t != null) trade.setMarkPrice(t.last);
    });
    market.start();
  }

  /// 释放页面资源。
  ///
  /// 包含文本控制器、行情 WebSocket、批量缓冲和交易通知器，防止页面销毁后
  /// 定时器继续回调造成内存泄漏或异常 setState。
  @override
  void dispose() {
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _tpCtrl.dispose();
    _slCtrl.dispose();
    market.dispose();
    trade.dispose();
    super.dispose();
  }

  /// 构建交易所主页面和全局点击空白处收起键盘的交互。
  ///
  /// 外层 GestureDetector 只处理空白点击，输入框、按钮和 Tab 仍由子组件消费事件。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F4F8),
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text(
          'BTC 永续 · Exchange Demo',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        actions: [
          AnimatedBuilder(
            animation: market,
            builder: (context, _) => _ConnectionChip(state: market.connState),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 以实际可用宽度做断点，窗口缩放和移动端横竖屏都能正常切换。
              return constraints.maxWidth >= 900
                  ? _buildWideBody(constraints)
                  : _buildCompactBody();
            },
          ),
        ),
      ),
    );
  }

  /// 构建宽屏布局：顶部行情与 K 线，底部左侧订单簿、右侧交易工作区。
  ///
  /// 图表高度和盘口宽度根据可用空间计算，避免固定尺寸在桌面窗口中过硬。
  Widget _buildWideBody(BoxConstraints constraints) {
    final chartHeight =
        (constraints.maxHeight * 0.30).clamp(190.0, 230.0).toDouble();
    final orderBookWidth =
        (constraints.maxWidth * 0.27).clamp(300.0, 360.0).toDouble();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _TickerBar(tickerNotifier: market.tickerNotifier),
          const SizedBox(height: 10),
          _KlineChart(store: market, height: chartHeight),
          const SizedBox(height: 10),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: orderBookWidth,
                  child: _OrderBookPanel(store: market),
                ),
                const SizedBox(width: 10),
                Expanded(child: _tradingWorkspace()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建窄屏布局：所有模块按业务优先级纵向排列到一个滚动视图中。
  ///
  /// 手机宽度下不再强行并排，避免订单簿和交易面板出现横向溢出。
  Widget _buildCompactBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _TickerBar(tickerNotifier: market.tickerNotifier),
        const SizedBox(height: 10),
        _KlineChart(store: market, height: 248),
        const SizedBox(height: 10),
        SizedBox(height: 380, child: _OrderBookPanel(store: market)),
        const SizedBox(height: 12),
        SizedBox(height: 560, child: _tradingWorkspace()),
      ],
    );
  }

  /// 创建共享两个 Store 和文本控制器的交易工作区。
  Widget _tradingWorkspace() {
    return _TradingWorkspace(
      trade: trade,
      qtyCtrl: _qtyCtrl,
      priceCtrl: _priceCtrl,
      tpCtrl: _tpCtrl,
      slCtrl: _slCtrl,
    );
  }
}

// ---------------------------------------------------------------- 顶栏行情

/// 顶部实时行情栏：展示 24h 最高、最低、成交量、最新价和涨跌幅。
///
/// 宽屏使用单行指标布局，窄屏改为两行紧凑布局，数据来源是独立的 Ticker 通知器。
class _TickerBar extends StatelessWidget {
  const _TickerBar({required this.tickerNotifier});

  final ValueNotifier<Ticker?> tickerNotifier;

  /// 根据可用宽度选择宽屏或窄屏行情排列。
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Ticker?>(
      valueListenable: tickerNotifier,
      builder: (context, ticker, _) {
        if (ticker == null) {
          return _panel(
            const SizedBox(
              height: 62,
              child: Center(child: Text('等待行情…')),
            ),
          );
        }

        final up = ticker.change24h >= 0;
        final color = up ? const Color(0xFF1FA875) : const Color(0xFFE05252);
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 720;
            return _panel(
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 14 : 16,
                  vertical: compact ? 12 : 10,
                ),
                child: compact
                    ? _compactTicker(ticker, color)
                    : _wideTicker(ticker, color),
              ),
            );
          },
        );
      },
    );
  }

  Widget _wideTicker(Ticker ticker, Color color) {
    return Row(
      children: [
        Text(
          ticker.symbol,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(width: 12),
        Text(
          ticker.last.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${ticker.change24h.toStringAsFixed(1)}  '
          '(${ticker.change24hPercent.toStringAsFixed(2)}%)',
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        _kv('24h 高', ticker.high24h.toStringAsFixed(1)),
        _kv('24h 低', ticker.low24h.toStringAsFixed(1)),
        _kv('24h 量', ticker.volume24h.toStringAsFixed(0)),
      ],
    );
  }

  Widget _compactTicker(Ticker ticker, Color color) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              ticker.symbol,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  ticker.last.toStringAsFixed(1),
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withAlpha(18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${ticker.change24hPercent >= 0 ? '+' : ''}'
                '${ticker.change24hPercent.toStringAsFixed(2)}%',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _compactMetric('24h 高', ticker.high24h.toStringAsFixed(1)),
            _compactMetric('24h 低', ticker.low24h.toStringAsFixed(1)),
            _compactMetric('24h 量', ticker.volume24h.toStringAsFixed(0)),
          ],
        ),
      ],
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(left: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A97A8)),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _compactMetric(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF8A97A8)),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _panel(Widget child) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE5EAF1)),
      ),
      child: child,
    );
  }
}

/// K 线图表容器：负责周期选择、手动横向滑动和当前蜡烛更新。
///
/// 图表只在周期切换后自动定位到最新一段；用户开始横向滑动后不会自动追随新数据，
/// 实时更新仅修改当前蜡烛，从而避免图表持续滚动。
class _KlineChart extends StatefulWidget {
  const _KlineChart({required this.store, required this.height});

  final MarketStore store;
  final double height;

  @override
  State<_KlineChart> createState() => _KlineChartState();
}

class _KlineChartState extends State<_KlineChart> {
  late final ScrollController _scrollController;
  bool _pendingJumpToEnd = true;
  int? _lastFirstKlineTs;
  double _slotWidth = 12;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.store.klineIntervalNotifier.addListener(_handleIntervalChanged);
    widget.store.klineVersion.addListener(_handleKlineChanged);
  }

  @override
  void dispose() {
    widget.store.klineIntervalNotifier.removeListener(_handleIntervalChanged);
    widget.store.klineVersion.removeListener(_handleKlineChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// 周期变化后只执行一次“定位到最右侧”，之后由用户手动滑动。
  void _handleIntervalChanged() {
    _pendingJumpToEnd = true;
    _scheduleJumpToEnd();
  }

  /// 处理 K 线刷新。
  ///
  /// 初始加载会定位到最右侧；周期滚动导致第一根蜡烛被移除时，主动补偿一个槽位，
  /// 让用户当前查看的历史区域保持不动，而不是被动跟着数据向左移动。
  void _handleKlineChanged() {
    final klines = widget.store.klines;
    if (klines.isEmpty) return;

    final firstTs = klines.first.ts;
    final shifted = _lastFirstKlineTs != null && firstTs != _lastFirstKlineTs;
    _lastFirstKlineTs = firstTs;

    if (_pendingJumpToEnd) {
      _scheduleJumpToEnd();
      return;
    }
    if (!shifted || !_scrollController.hasClients) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = (_scrollController.offset + _slotWidth)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      _scrollController.jumpTo(target);
    });
  }

  void _scheduleJumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pendingJumpToEnd || !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      _pendingJumpToEnd = false;
    });
  }

  /// 构建工具栏和可横向滑动的固定高度 K 线画布。
  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5EAF1)),
      ),
      child: Column(
        children: [
          _KlineToolbar(store: widget.store),
          const Divider(height: 1, color: Color(0xFFE8EDF4)),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return ValueListenableBuilder<int>(
                  valueListenable: widget.store.klineVersion,
                  builder: (context, version, _) {
                    if (widget.store.klines.isEmpty) {
                      return const Center(child: Text('K 线生成中…'));
                    }

                    final interval = widget.store.klineIntervalNotifier.value;
                    final slotWidth = constraints.maxWidth < 600 ? 10.5 : 12.0;
                    _slotWidth = slotWidth;
                    final contentWidth =
                        (widget.store.klines.length * slotWidth)
                            .clamp(constraints.maxWidth, double.infinity)
                            .toDouble();

                    return Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      thickness: 3,
                      radius: const Radius.circular(2),
                      scrollbarOrientation: ScrollbarOrientation.bottom,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: SizedBox(
                          width: contentWidth,
                          height: constraints.maxHeight,
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: KlinePainter(
                                klines: widget.store.klines,
                                version: version,
                                interval: interval,
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// K 线标题栏：提供 15分/1时/4时/1日/1月周期选择并显示当前价格。
class _KlineToolbar extends StatelessWidget {
  const _KlineToolbar({required this.store});

  final MarketStore store;

  /// 构建周期按钮和当前价格信息。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Text(
              '价格走势',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ValueListenableBuilder<KlineInterval>(
                  valueListenable: store.klineIntervalNotifier,
                  builder: (context, selected, _) {
                    return Row(
                      children: [
                        for (final interval in KlineInterval.values) ...[
                          _intervalChip(interval,
                              selected: interval == selected),
                          if (interval != KlineInterval.values.last)
                            const SizedBox(width: 6),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<Ticker?>(
              valueListenable: store.tickerNotifier,
              builder: (context, ticker, _) {
                if (ticker == null) {
                  return const Text(
                    '--',
                    style: TextStyle(
                      color: Color(0xFF8A97A8),
                      fontSize: 12,
                    ),
                  );
                }
                final color = ticker.change24h >= 0
                    ? const Color(0xFF1FA875)
                    : const Color(0xFFE05252);
                return Text(
                  ticker.last.toStringAsFixed(1),
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _intervalChip(
    KlineInterval interval, {
    required bool selected,
  }) {
    return InkWell(
      onTap: selected ? null : () => store.changeKlineInterval(interval),
      borderRadius: BorderRadius.circular(5),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEAF2FC) : const Color(0xFFF4F6F9),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          interval.label,
          style: TextStyle(
            color: selected ? const Color(0xFF0B65B3) : const Color(0xFF7A879A),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 订单簿

/// 深度订单簿面板：展示 Top-N 买卖盘、数量、中间价和累计深度背景。
///
/// 面板只订阅 [MarketStore.bookVersion]，并通过 RepaintBoundary 把高频绘制隔离开。
class _OrderBookPanel extends StatelessWidget {
  const _OrderBookPanel({required this.store});

  final MarketStore store;

  /// 从 [MarketStore.book] 读取聚合盘口并交给 OrderBookPainter 绘制。
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5EAF1)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                    child: Text('价格(USDT)',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF8A97A8)))),
                Text('数量(BTC)',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8A97A8))),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: store.bookVersion,
              builder: (context, version, _) {
                final asks = store.book
                    .aggregatedTopAsks(store.depthCount, store.tickSize);
                final bids = store.book
                    .aggregatedTopBids(store.depthCount, store.tickSize);
                return RepaintBoundary(
                  child: CustomPaint(
                    painter: OrderBookPainter(
                        bids: bids, asks: asks, version: version),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 交易工作区

/// 交易工作区：组合下单、持仓和订单三个 Tab。
///
/// 三个子面板共享同一个 [TradeStore]，因此在行情或交易变化后可以各自局部刷新。
class _TradingWorkspace extends StatelessWidget {
  const _TradingWorkspace({
    required this.trade,
    required this.qtyCtrl,
    required this.priceCtrl,
    required this.tpCtrl,
    required this.slCtrl,
  });

  final TradeStore trade;
  final TextEditingController qtyCtrl;
  final TextEditingController priceCtrl;
  final TextEditingController tpCtrl;
  final TextEditingController slCtrl;

  /// 构建下单、持仓、订单三个 Tab。
  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5EAF1)),
      ),
      child: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const TabBar(
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Color(0xFFE8EDF4),
              tabs: [
                Tab(text: '下单'),
                Tab(text: '持仓'),
                Tab(text: '订单'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _TradePanel(
                    trade: trade,
                    qtyCtrl: qtyCtrl,
                    priceCtrl: priceCtrl,
                    tpCtrl: tpCtrl,
                    slCtrl: slCtrl,
                  ),
                  _PositionsPanel(trade: trade),
                  _OrdersPanel(trade: trade),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 交易面板

/// 下单面板：收集订单类型、价格、数量、杠杆、保证金模式及止盈止损参数。
class _TradePanel extends StatefulWidget {
  const _TradePanel({
    required this.trade,
    required this.qtyCtrl,
    required this.priceCtrl,
    required this.tpCtrl,
    required this.slCtrl,
  });

  final TradeStore trade;
  final TextEditingController qtyCtrl;
  final TextEditingController priceCtrl;
  final TextEditingController tpCtrl;
  final TextEditingController slCtrl;

  @override
  State<_TradePanel> createState() => _TradePanelState();
}

/// 下单面板状态：维护表单控件并根据用户操作提交模拟订单。
class _TradePanelState extends State<_TradePanel> {
  /// 构建限价/市价、杠杆和开平仓表单。
  ///
  /// 表单只负责修改 [TradeStore] 的参数；价格和标记价的业务联动由 Store 处理。
  @override
  Widget build(BuildContext context) {
    final t = widget.trade;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _orderTypeBtn(OrderType.limit, '限价单'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _orderTypeBtn(OrderType.market, '市价单'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _field(widget.priceCtrl, '价格 (USDT)',
              enabled: t.orderType == OrderType.limit),
          const SizedBox(height: 8),
          _field(widget.qtyCtrl, '数量 (BTC)'),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('杠杆', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  value: t.leverage.clamp(1, 100).toDouble(),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  label: '${t.leverage.round()}x',
                  onChanged: (v) =>
                      setState(() => t.leverage = v.roundToDouble()),
                ),
              ),
              Text('${t.leverage.round()}x',
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
          Row(
            children: [
              const Text('全仓', style: TextStyle(fontSize: 13)),
              Switch(
                value: t.marginMode == MarginMode.cross,
                onChanged: (v) => setState(() =>
                    t.marginMode = v ? MarginMode.cross : MarginMode.isolated),
              ),
              const Text('逐仓', style: TextStyle(fontSize: 13)),
              const Spacer(),
              const Text('只减仓', style: TextStyle(fontSize: 13)),
              Switch(
                value: t.reduceOnly,
                onChanged: (v) => setState(() => t.reduceOnly = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _field(widget.tpCtrl, '止盈 TP (USDT)'),
          const SizedBox(height: 8),
          _field(widget.slCtrl, '止损 SL (USDT)'),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1FA875),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => _submit(OrderSide.buy),
                  child: const Text('买入 / 开多'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE05252),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => _submit(OrderSide.sell),
                  child: const Text('卖出 / 开空'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _orderTypeBtn(OrderType type, String label) {
    final selected = widget.trade.orderType == type;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? Colors.white : const Color(0xFF3A4A5F),
        backgroundColor: selected ? const Color(0xFF3D5A80) : Colors.white,
      ),
      onPressed: () => setState(() => widget.trade.orderType = type),
      child: Text(label),
    );
  }

  Widget _field(TextEditingController ctrl, String label,
      {bool enabled = true}) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    );
  }

  /// 校验输入并提交一笔模拟订单。
  ///
  /// 解析失败时使用默认值以保证 Demo 可操作；真实项目应在提交前显示校验错误，
  /// 并由交易网关返回订单号、成交状态和拒单原因。
  void _submit(OrderSide side) {
    final t = widget.trade;
    t.qty = double.tryParse(widget.qtyCtrl.text) ?? 0.01;
    t.price = double.tryParse(widget.priceCtrl.text) ?? 60000;
    t.tpPrice = double.tryParse(widget.tpCtrl.text);
    t.slPrice = double.tryParse(widget.slCtrl.text);
    t.placeOrder(side);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 800),
        content:
            Text('已提交：${side == OrderSide.buy ? '买入' : '卖出'} ${t.qty} BTC'),
      ),
    );
  }
}

// ---------------------------------------------------------------- 持仓

/// 持仓面板：展示账户权益、可用资金、保证金和每个持仓的实时未实现盈亏。
class _PositionsPanel extends StatelessWidget {
  const _PositionsPanel({required this.trade});

  final TradeStore trade;

  /// 监听交易状态并展示账户概览和持仓列表。
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: trade,
      builder: (context, _) {
        final active = trade.positions.where((p) => p.size != 0).toList();
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _accountCard(),
              const SizedBox(height: 12),
              Expanded(
                child: active.isEmpty
                    ? const Center(child: Text('暂无持仓，去下单吧'))
                    : ListView.separated(
                        itemCount: active.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) =>
                            _positionCard(active[i], i),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _accountCard() {
    final uPnl = trade.accountUnrealizedPnl();
    final color = uPnl >= 0 ? const Color(0xFF1FA875) : const Color(0xFFE05252);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFD),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5EAF1)),
      ),
      child: Row(
        children: [
          _metric('账户权益', (trade.available + trade.margin).toStringAsFixed(2)),
          _metric('可用', trade.available.toStringAsFixed(2)),
          _metric('占用保证金', trade.margin.toStringAsFixed(2)),
          _metric('未实现盈亏', uPnl.toStringAsFixed(2), valueColor: color),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, {Color? valueColor}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF8A97A8))),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: valueColor)),
        ],
      ),
    );
  }

  /// 构建单条持仓卡片，并计算当前标记价下的盈亏与强平价。
  Widget _positionCard(Position p, int index) {
    final uPnl = trade.engine.unrealizedPnl(p, trade.markPrice);
    final liq = trade.engine.liquidationPrice(p);
    final color = uPnl >= 0 ? const Color(0xFF1FA875) : const Color(0xFFE05252);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5EAF1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                  p.isLong
                      ? '多  ${p.absSize.toStringAsFixed(4)} BTC'
                      : '空  ${p.absSize.toStringAsFixed(4)} BTC',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(
                  '${p.marginMode == MarginMode.cross ? '全仓' : '逐仓'} · ${p.leverage.round()}x',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF8A97A8))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _pv('开仓价', p.entryPrice.toStringAsFixed(1)),
              _pv('标记价', trade.markPrice.toStringAsFixed(1)),
              _pv('强平价', liq.toStringAsFixed(1)),
              _pv('未实现盈亏', uPnl.toStringAsFixed(2), valueColor: color),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              onPressed: () => trade.closePositionAtMarket(index),
              child: const Text('市价平仓'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pv(String label, String value, {Color? valueColor}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF8A97A8))),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: valueColor)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 订单记录

/// 订单记录面板：展示本地下单历史和模拟成交状态。
class _OrdersPanel extends StatelessWidget {
  const _OrdersPanel({required this.trade});

  final TradeStore trade;

  /// 监听订单列表并根据空状态显示提示或订单记录。
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: trade,
      builder: (context, _) {
        if (trade.orders.isEmpty) return const Center(child: Text('暂无订单'));
        return ListView.separated(
          padding: const EdgeInsets.all(14),
          itemCount: trade.orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, i) {
            final o = trade.orders[i];
            final sideColor = o.side == OrderSide.buy
                ? const Color(0xFF1FA875)
                : const Color(0xFFE05252);
            return ListTile(
              dense: true,
              tileColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0xFFE5EAF1)),
              ),
              leading: Text(o.side == OrderSide.buy ? '买' : '卖',
                  style:
                      TextStyle(color: sideColor, fontWeight: FontWeight.bold)),
              title: Text(
                  '${o.type == OrderType.limit ? '限价' : '市价'} ${o.qty} BTC'),
              subtitle: Text('${o.id} · ${o.status}'),
              trailing:
                  Text(o.price == null ? '市价' : o.price!.toStringAsFixed(1)),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 连接状态

/// WebSocket 连接状态标签：把连接状态映射为颜色和中文提示。
class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.state});

  final WsConnectionState state;

  /// 把连接状态映射为“已连接/连接中/重连中/已关闭”等中文标签。
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      WsConnectionState.connected => ('已连接', const Color(0xFF1FA875)),
      WsConnectionState.connecting => ('连接中', const Color(0xFFE0A100)),
      WsConnectionState.reconnecting => ('重连中', const Color(0xFFE0A100)),
      WsConnectionState.closed => ('已关闭', const Color(0xFF8A97A8)),
      WsConnectionState.idle => ('空闲', const Color(0xFF8A97A8)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:
            label == '已连接' ? const Color(0xFFEAF8F2) : const Color(0xFFFFF6E0),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}
