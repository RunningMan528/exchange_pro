// 模块：订单簿深度绘制
// 作用：把聚合后的买盘、卖盘和累计深度绘制成交易所风格的盘口列表。
// 绘制内容：卖盘倒序排列、中间价差、买盘正序排列，以及价格背后的累计深度条。
// 性能：通过 version 控制 shouldRepaint，外层再使用 RepaintBoundary 隔离高频刷新。

import 'package:flutter/material.dart';

import '../core/models.dart';

/// 订单簿 CustomPainter：
/// - 用 [version] 做 shouldRepaint 判断，盘口不变时跳过重绘；
/// - 外层配合 RepaintBoundary，隔离高频订单簿与其他 UI 的绘制。
class OrderBookPainter extends CustomPainter {
  OrderBookPainter({
    required this.bids,
    required this.asks,
    required this.version,
  });

  final List<OrderBookLevel> bids; // 降序，最优买价在前
  final List<OrderBookLevel> asks; // 升序，最优卖价在前（绘制时倒序）
  final int version;

  static const Color askColor = Color(0xFFE05252);
  static const Color bidColor = Color(0xFF1FA875);

  /// 绘制完整订单簿。
  ///
  /// 先计算买卖盘累计数量，再按“卖盘倒序 -> 中间价差 -> 买盘正序”的顺序
  /// 绘制，让最优价格始终贴近中间区域，符合交易所盘口阅读习惯。
  @override
  void paint(Canvas canvas, Size size) {
    // 计算累计深度，用于绘制深度条比例。
    double cumBid = 0;
    final bidCum = <double>[];
    for (final l in bids) {
      cumBid += l.size;
      bidCum.add(cumBid);
    }
    double cumAsk = 0;
    final askCum = <double>[];
    for (final l in asks.reversed) {
      cumAsk += l.size;
      askCum.add(cumAsk);
    }
    final maxCum = [cumBid, cumAsk, 1e-9].reduce((a, b) => a > b ? a : b);

    final rows = asks.length + bids.length + 1; // +1 为中间价行
    final rowH = size.height / rows;
    final spread = asks.isEmpty || bids.isEmpty
        ? 0.0
        : asks.first.price - bids.first.price;

    var y = 0.0;

    // 卖盘：价格从高到低（最优卖价贴近中间）。
    final asksDesc = asks.reversed.toList();
    for (var i = 0; i < asksDesc.length; i++) {
      final l = asksDesc[i];
      final cum = askCum[asksDesc.length - 1 - i];
      _paintRow(canvas, size, y, rowH, l, cum / maxCum, askColor,
          alignLeft: false);
      y += rowH;
    }

    // 中间价 / 价差。
    _paintSpread(canvas, size, y, rowH, spread);
    y += rowH;

    // 买盘：价格从高到低（最优买价贴近中间）。
    for (var i = 0; i < bids.length; i++) {
      final l = bids[i];
      _paintRow(canvas, size, y, rowH, l, bidCum[i] / maxCum, bidColor,
          alignLeft: true);
      y += rowH;
    }
  }

  /// 绘制单个价格档位及其累计深度背景。
  void _paintRow(Canvas canvas, Size size, double y, double h,
      OrderBookLevel level, double ratio, Color color,
      {required bool alignLeft}) {
    final barW = size.width * ratio.clamp(0.0, 1.0);
    final barRect = alignLeft
        ? Rect.fromLTWH(0, y, barW, h)
        : Rect.fromLTWH(size.width - barW, y, barW, h);

    canvas.drawRect(barRect, Paint()..color = color.withAlpha(36));

    final priceText = level.price.toStringAsFixed(1);
    final sizeText = level.size.toStringAsFixed(4);
    _drawText(canvas, priceText, 0, y, h, color, align: TextAlign.left);
    _drawText(
        canvas, sizeText, size.width * 0.55, y, h, const Color(0xFF7A879A),
        align: TextAlign.right);
  }

  /// 绘制买卖价差与中间价。
  void _paintSpread(
      Canvas canvas, Size size, double y, double h, double spread) {
    final mid = (bids.isNotEmpty ? bids.first.price : 0) +
        (asks.isNotEmpty ? asks.first.price : 0);
    final text =
        '价差 ${spread.toStringAsFixed(1)}  中间价 ${(mid / 2).toStringAsFixed(1)}';
    _drawText(canvas, text, 0, y, h, const Color(0xFF516072),
        align: TextAlign.center);
  }

  /// 使用等宽字体绘制盘口数值，并让文本在行高内垂直居中。
  void _drawText(
      Canvas canvas, String text, double x, double y, double h, Color color,
      {required TextAlign align}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: double.infinity);

    final dy = y + (h - painter.height) / 2;
    painter.paint(canvas, Offset(x, dy));
  }

  /// 只在盘口版本变化时重绘，避免其它区域刷新导致订单簿重复绘制。
  @override
  bool shouldRepaint(OrderBookPainter oldDelegate) =>
      oldDelegate.version != version;
}
