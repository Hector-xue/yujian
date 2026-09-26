{{flutter_js}}
{{flutter_build_config}}

// 中文字形回退：引擎默认从 fonts.gstatic.com 拉 Noto，国内经常连不上，页面就缺字。
// fonts.gstatic.cn 是同一套文件（Google 的国内域名，路径一致），国内外都能访问。
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: "https://fonts.gstatic.cn/s/",
  },
});
