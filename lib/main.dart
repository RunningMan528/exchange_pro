// 模块：应用入口与全局主题
// 作用：初始化 Flutter App，配置 Material 3 主题、主题色、滑块样式和默认首页。
// 调用链：main() -> ExchangeApp -> ExchangeScreen。
// 说明：Demo 不依赖路由、登录或真实后端，启动后直接进入交易所单页工作台。

import 'package:flutter/material.dart';

import 'app/exchange_screen.dart';

/// 应用启动入口。
///
/// Demo 没有异步初始化、依赖注入或路由恢复，因此直接挂载 [ExchangeApp]；
/// 页面创建后会由 [ExchangeScreen] 自行启动模拟行情连接。
void main() {
  runApp(const ExchangeApp());
}

/// 应用根组件：统一设置 Material 3 主题并把交易所工作台作为首页。
///
/// 当前只有一个页面，所以这里不引入路由框架；真实项目可在这一层接入
/// go_router、深浅色主题、多语言和全局错误边界。
class ExchangeApp extends StatelessWidget {
  const ExchangeApp({super.key});

  /// 构建全局 [MaterialApp]。
  ///
  /// 主题色和控件样式在这里统一配置，页面内部只需要关注交易业务布局。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '交易所 Flutter Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B4DA2)),
        sliderTheme: const SliderThemeData(
            showValueIndicator: ShowValueIndicator.onDrag),
      ),
      home: const ExchangeScreen(),
    );
  }
}
