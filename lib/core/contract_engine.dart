// 模块：USDT-M 合约计算引擎
// 作用：提供开仓合并、平仓结算、未实现盈亏、初始保证金和强平价等纯逻辑计算。
// 设计特点：不依赖 Flutter，可在客户端展示、策略计算和服务端对账中复用同一套公式。
// 简化边界：强平价采用单仓、逐仓近似公式，真实交易所还会考虑维持保证金梯度和资金费。

import 'dart:math';
import 'models.dart';

/// USDT-M 合约计算引擎。
///
/// 这个类只处理数学和持仓状态，不访问网络、不发通知，也不依赖 Flutter。
/// 因此客户端可以用它展示盈亏，服务端或其他策略模块也可以复用公式进行对账。
class ContractEngine {
  /// 维护保证金率（示例，真实产品按梯度）。
  final double maintenanceMarginRate;

  ContractEngine({this.maintenanceMarginRate = 0.005});

  /// 计算持仓在当前标记价下的未实现盈亏。
  ///
  /// 多单公式为 `(mark - entry) * size`，空单公式为
  /// `(entry - mark) * abs(size)`；标记价应来自可靠的指数价或合约标记价。
  double unrealizedPnl(Position pos, double markPrice) {
    if (pos.isLong) return (markPrice - pos.entryPrice) * pos.size;
    return (pos.entryPrice - markPrice) * pos.absSize;
  }

  /// 建立或增加持仓。
  ///
  /// 若没有同向持仓则创建新仓位；若已有同向仓位则把数量相加，并按
  /// `旧数量和*旧均价 + 新数量和*新成交价` 计算加权平均开仓价。
  Position open(
    Position? existing, {
    required OrderSide side,
    required double qty,
    required double price,
    required double leverage,
    required MarginMode marginMode,
    double? tpPrice,
    double? slPrice,
  }) {
    final signedQty = side == OrderSide.buy ? qty : -qty;
    if (existing == null || existing.size == 0) {
      return Position(
        symbol: 'BTC-USDT',
        size: signedQty,
        entryPrice: price,
        leverage: leverage,
        marginMode: marginMode,
        tpPrice: tpPrice,
        slPrice: slPrice,
      );
    }
    // 同向加仓：新均价 = (旧数量*旧价 + 新数量*新价) / 总数量。
    final newSize = existing.size + signedQty;
    final avgPrice = (existing.absSize * existing.entryPrice + qty * price) /
        (existing.absSize + qty);
    return existing.copyWith(size: newSize, entryPrice: avgPrice);
  }

  /// 减少或关闭持仓并结算已实现盈亏。
  ///
  /// 平多必须卖出、平空必须买入；qty 超过持仓时按剩余全部数量处理。
  /// 返回的新 Position 保留原杠杆和保证金模式，并把 realizedPnl 累加进去。
  Position? close(
    Position pos, {
    required OrderSide closeSide,
    required double qty,
    required double price,
  }) {
    if (pos.size == 0) return pos;
    final closingLong = pos.isLong && closeSide == OrderSide.sell;
    final closingShort = !pos.isLong && closeSide == OrderSide.buy;
    if (!closingLong && !closingShort) {
      throw ArgumentError('平仓方向与持仓方向不符');
    }

    final closeAbs = min(qty, pos.absSize);
    final realized = pos.isLong
        ? (price - pos.entryPrice) * closeAbs
        : (pos.entryPrice - price) * closeAbs;
    final remaining = pos.isLong ? pos.size - closeAbs : pos.size + closeAbs;

    if (remaining.abs() < 1e-9) {
      return Position(
        symbol: pos.symbol,
        size: 0,
        entryPrice: 0,
        leverage: pos.leverage,
        marginMode: pos.marginMode,
        realizedPnl: pos.realizedPnl + realized,
      );
    }
    return pos.copyWith(
        size: remaining, realizedPnl: pos.realizedPnl + realized);
  }

  /// 估算强平价。
  ///
  /// 当前使用单仓、逐仓近似公式，主要用于 Demo 展示；真实交易所会考虑
  /// 维持保证金梯度、资金费率、标记价和账户其他仓位。
  double liquidationPrice(Position pos) {
    if (pos.size == 0) return 0;
    final direction = pos.isLong ? 1.0 : -1.0;
    return pos.entryPrice *
        (1 -
            direction * (1 / pos.leverage) +
            direction * maintenanceMarginRate);
  }

  /// 计算持仓初始保证金。
  ///
  /// 公式为 `持仓数量 * 标记价 / 杠杆`，用于账户可用余额和占用保证金展示。
  double initialMargin(Position pos, double markPrice) {
    return pos.absSize * markPrice / pos.leverage;
  }
}
