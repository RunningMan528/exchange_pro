// 模块：K 线自定义绘制
// 作用：不依赖第三方图表库，直接使用 CustomPainter 绘制小蜡烛、影线、网格和最新价。
// 输入：最近一段 Kline 数据和一个版本号；版本变化时才重新绘制。
// 性能：固定蜡烛槽位宽度，由外层横向滚动查看历史，避免持续自动追随造成视觉抖动。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';

/// 轻量 K 线绘制器。
///
/// 蜡烛实体保持窄小，移动端也会自动限制最大实体宽度；同时绘制价格网格、
/// 最新价虚线和右侧价格标签，让 Demo 在不需要图表库的情况下也能保持清晰。
class KlinePainter extends CustomPainter {
  KlinePainter({
    required this.klines,
    required this.version,
    required this.interval,
  });

  final List<Kline> klines;
  final int version;
  final KlineInterval interval;

  static const Color upColor = Color(0xFF1FA875);
  static const Color downColor = Color(0xFFE05252);

  static const double _priceAxisWidth = 58;
  static const double _topPadding = 6;
  static const double _bottomAxisHeight = 20;

  /// 绘制完整 K 线图层。
  ///
  /// 流程：计算价格上下界和留白 -> 绘制网格 -> 将 OHLC 转换为屏幕坐标 ->
  /// 绘制影线和圆角实体 -> 绘制最新价虚线与右侧价格标签。
  @override
  void paint(Canvas canvas, Size size) {
    if (klines.isEmpty || size.width < 90 || size.height < 40) return;

    final chartRight = math.max(80.0, size.width - _priceAxisWidth);
    final chart = Rect.fromLTWH(
      0,
      _topPadding,
      chartRight,
      math.max(0, size.height - _topPadding - _bottomAxisHeight),
    );
    if (chart.width <= 0 || chart.height <= 0) return;

    var minPrice = klines.first.low;
    var maxPrice = klines.first.high;
    for (final kline in klines) {
      minPrice = math.min(minPrice, kline.low);
      maxPrice = math.max(maxPrice, kline.high);
    }

    final rawRange = maxPrice - minPrice;
    final padding =
        math.max(rawRange * 0.08, rawRange.abs() < 1e-9 ? 1.0 : 0.5);
    minPrice -= padding;
    maxPrice += padding;
    final range = math.max(maxPrice - minPrice, 1e-9);

    _drawGrid(canvas, size, chart, minPrice, maxPrice);
    _drawTimeAxis(canvas, chart);

    canvas.save();
    canvas.clipRect(chart);

    final slot = chart.width / klines.length;
    final bodyWidth = (slot * 0.62).clamp(1.6, 7.2).toDouble();
    final bodyRadius = Radius.circular(math.min(1.6, bodyWidth * 0.28));

    for (var i = 0; i < klines.length; i++) {
      final kline = klines[i];
      final x = chart.left + i * slot + slot / 2;
      final yHigh = _priceToY(kline.high, chart, maxPrice, range);
      final yLow = _priceToY(kline.low, chart, maxPrice, range);
      final yOpen = _priceToY(kline.open, chart, maxPrice, range);
      final yClose = _priceToY(kline.close, chart, maxPrice, range);
      final color = kline.close >= kline.open ? upColor : downColor;

      final wickPaint = Paint()
        ..color = color
        ..strokeWidth = bodyWidth >= 5 ? 1.15 : 1
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      // 上下影线：使用很细的线，避免 K 线视觉上变成柱状图。
      canvas.drawLine(Offset(x, yHigh), Offset(x, yLow), wickPaint);

      // 实体：开盘价与收盘价重合时保留一个最小的“十字”高度。
      final bodyCenterY = (yOpen + yClose) / 2;
      final bodyHeight = math.max((yClose - yOpen).abs(), 1.4);
      final bodyRect = Rect.fromCenter(
        center: Offset(x, bodyCenterY),
        width: bodyWidth,
        height: bodyHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bodyRect, bodyRadius),
        Paint()
          ..color = color
          ..isAntiAlias = true,
      );
    }

    canvas.restore();

    _drawLastPrice(canvas, chart, range, maxPrice);
  }

  /// 绘制价格水平线、时间竖线和右侧价格刻度。
  void _drawGrid(
    Canvas canvas,
    Size size,
    Rect chart,
    double minPrice,
    double maxPrice,
  ) {
    final gridPaint = Paint()
      ..color = const Color(0xFFEDF1F6)
      ..strokeWidth = 1;
    final strongGridPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;

    for (var i = 0; i <= 3; i++) {
      final y = chart.top + chart.height * i / 3;
      canvas.drawLine(
        Offset(chart.left, y),
        Offset(chart.right, y),
        i == 0 || i == 3 ? strongGridPaint : gridPaint,
      );

      final price = maxPrice - (maxPrice - minPrice) * i / 3;
      _drawPriceLabel(canvas, size, y, price);
    }

    for (var i = 1; i <= 3; i++) {
      final x = chart.left + chart.width * i / 4;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), gridPaint);
    }
  }

  /// 在右侧价格轴绘制一个价格刻度文本。
  /// 绘制横向时间刻度。
  ///
  /// 时间刻度跟随整张可滚动画布移动，用户左右滑动时可以看到对应周期的日期。
  void _drawTimeAxis(Canvas canvas, Rect chart) {
    if (klines.isEmpty || chart.width < 120) return;

    final labelCount = chart.width < 600 ? 3 : 5;
    final step = math.max(1, (klines.length / labelCount).ceil());
    for (var i = 0; i < klines.length; i += step) {
      final x = chart.left + (i + 0.5) / klines.length * chart.width;
      final painter = TextPainter(
        text: TextSpan(
          text: _formatTime(klines[i].ts),
          style: const TextStyle(
            color: Color(0xFF8A97A8),
            fontSize: 9.5,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final dx = (x - painter.width / 2)
          .clamp(0.0, math.max(0.0, chart.right - painter.width))
          .toDouble();
      painter.paint(canvas, Offset(dx, chart.bottom + 3));
    }
  }

  /// 按当前周期格式化时间刻度。
  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');

    return switch (interval) {
      KlineInterval.month1 => '${date.year}-$month',
      KlineInterval.day1 => '$month-$day',
      _ => '$month-$day $hour:$minute',
    };
  }

  /// 在右侧价格轴绘制一个价格刻度文本。
  void _drawPriceLabel(Canvas canvas, Size size, double y, double price) {
    final painter = TextPainter(
      text: TextSpan(
        text: _formatPrice(price),
        style: const TextStyle(
          color: Color(0xFF8A97A8),
          fontSize: 10,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _priceAxisWidth - 4);

    painter.paint(
      canvas,
      Offset(size.width - painter.width,
          (y - painter.height / 2).clamp(0, size.height)),
    );
  }

  /// 绘制最新价虚线及右侧深色价格标签。
  ///
  /// 标签使用最近一根 K 线的 close，帮助用户快速定位当前价格在图表中的高度。
  void _drawLastPrice(
      Canvas canvas, Rect chart, double range, double maxPrice) {
    final last = klines.last.close;
    final y = _priceToY(last, chart, maxPrice, range);
    final linePaint = Paint()
      ..color = const Color(0xFF607D9B)
      ..strokeWidth = 1;

    const dashWidth = 4.0;
    const dashGap = 3.0;
    var x = chart.left;
    while (x < chart.right) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dashWidth, chart.right), y),
        linePaint,
      );
      x += dashWidth + dashGap;
    }

    final labelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(chart.right + 4, y - 9, _priceAxisWidth - 8, 18),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      labelRect,
      Paint()..color = const Color(0xFF334A63),
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: _formatPrice(last),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: labelRect.width - 6);

    textPainter.paint(
      canvas,
      Offset(
        labelRect.left + (labelRect.width - textPainter.width) / 2,
        labelRect.top + (labelRect.height - textPainter.height) / 2,
      ),
    );
  }

  /// 把价格线性映射到图表区域的纵坐标。
  double _priceToY(double price, Rect chart, double maxPrice, double range) {
    return chart.top + (maxPrice - price) / range * chart.height;
  }

  String _formatPrice(double price) {
    if (price >= 1000) return price.toStringAsFixed(1);
    if (price >= 10) return price.toStringAsFixed(2);
    return price.toStringAsFixed(4);
  }

  /// 只有 K 线版本或可见数量变化时才重绘。
  @override
  bool shouldRepaint(KlinePainter oldDelegate) =>
      oldDelegate.version != version ||
      oldDelegate.interval != interval ||
      oldDelegate.klines.length != klines.length;
}
