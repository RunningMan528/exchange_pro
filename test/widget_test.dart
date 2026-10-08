// 模块：响应式页面 Widget 测试
// 作用：在窄屏和宽屏尺寸下启动 ExchangeApp，检查关键区域渲染和布局溢出。
// 说明：测试只验证 UI 骨架，行情、订单簿和交易公式的深度验证位于 tool/verify.dart。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exchange_flutter_demo/main.dart';

void main() {
  // 模拟手机尺寸，验证纵向布局不会产生 RenderFlex 溢出。
  testWidgets('窄屏交易所页面可以正常渲染', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ExchangeApp());
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('BTC 永续 · Exchange Demo'), findsOneWidget);
    expect(find.text('价格走势'), findsOneWidget);
    expect(find.text('下单'), findsOneWidget);
    final compactException = tester.takeException();
    expect(
      compactException,
      isNull,
      reason: compactException is FlutterError
          ? compactException.toStringDeep()
          : '$compactException',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // 模拟桌面尺寸，验证订单簿与交易工作区可以并排显示。
  testWidgets('宽屏交易所页面可以正常渲染', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ExchangeApp());
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('BTC 永续 · Exchange Demo'), findsOneWidget);
    expect(find.text('价格走势'), findsOneWidget);
    expect(find.text('价格(USDT)'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
