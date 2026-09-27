#version 460 core
#include <flutter/runtime_effect.glsl>

// 玻璃：一份着色器两种用法。
//   uMode = 1：内容卡片对"预模糊的全局背景"按屏幕位置取样（背景静止，效果同真磨砂，每帧零回读），
//              加折射 / 饱和 / 极淡着色 / 沿光向亮边。
//   uMode = 2：只画"玻璃面"（着色 + 亮边 + 内侧暗线 + 顶部面光），不取样任何纹理；
//              盖在真 BackdropFilter（模糊 + 饱和）上面给底栏用。底栏不再把着色器当 BackdropFilter 用：
//              引擎给 BackdropFilter 着色器的纹理不是形状本身（外扩 / 裁边 / 降采样 / 切页时整屏），
//              坐标猜错就是胶囊里的黑线白弧和返回时的黑闪，猜对与否在设备上才知道——不赌。

uniform vec2 uSize;        // mode 1：背景纹理的逻辑尺寸
uniform vec2 uOrigin;      // mode 1：形状左上角的屏幕逻辑坐标
uniform vec2 uRect;        // 形状尺寸（逻辑 px）
uniform float uRadius;     // 圆角
uniform float uMode;
uniform vec4 uTint;        // rgb + 着色强度（非预乘）
uniform float uSaturation; // mode 1：1 = 原样，1.5 ≈ iOS 材质
uniform float uThickness;  // 折射带宽度 px
uniform float uRefract;    // 折射位移 px
uniform float uLight;      // 亮边强度
uniform sampler2D uBackdrop;

out vec4 fragColor;

float sdRoundRect(vec2 p, vec2 hs, float r) {
  vec2 d = abs(p) - (hs - vec2(r));
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

vec3 sampleBg(vec2 q) {
  vec2 uv = clamp((uOrigin + q) / uSize, vec2(0.0), vec2(1.0));
  // 纹理是预乘 alpha 的。背景按 0.5 倍截图时屏幕宽高常是半像素（393 → 196.5），最后一行 / 一列半透明，
  // 模糊后往里晕开一圈；直接拿 rgb 就是一圈发暗的边（屏幕最下面那道灰）。除回 alpha 取真实颜色
  vec4 t = texture(uBackdrop, uv);
  return t.a > 0.004 ? t.rgb / t.a : t.rgb;
}

void main() {
  vec2 p = FlutterFragCoord().xy; // 形状局部坐标（Paint 着色器：画布原点 = 形状左上角）
  vec2 hs = uRect * 0.5;
  float r = min(uRadius, min(hs.x, hs.y));
  vec2 c = p - hs;
  float sd = sdRoundRect(c, hs, r);
  float aa = 1.0 - smoothstep(-0.8, 0.6, sd);
  if (aa <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  // 外法线 = SDF 梯度
  float e = 0.75;
  vec2 n = vec2(sdRoundRect(c + vec2(e, 0.0), hs, r) - sdRoundRect(c - vec2(e, 0.0), hs, r),
                sdRoundRect(c + vec2(0.0, e), hs, r) - sdRoundRect(c - vec2(0.0, e), hs, r));
  n = normalize(n + vec2(1e-5, 0.0));
  float depth = clamp(-sd / max(uThickness, 1.0), 0.0, 1.0); // 0 = 边缘，1 = 内部

  vec2 L = normalize(vec2(-0.45, -0.89)); // 光从左上来
  float lit = max(dot(n, L), 0.0);
  float shade = max(dot(n, -L), 0.0);
  float rimW = 2.2;
  float rim = 1.0 - smoothstep(0.0, rimW, -sd); // 最外 2px：一圈细亮边，受光侧最亮，背光侧也留一点反光
  float fresnel = smoothstep(rimW, rimW + 1.5, -sd) * (1.0 - smoothstep(rimW + 1.5, rimW + 7.0, -sd)); // 亮边内侧一道极淡的暗线，玻璃才有厚度
  float sheen = 1.0 - smoothstep(0.0, 0.6, p.y / uRect.y); // 顶部一道柔和面光
  float rimLight = rim * (0.25 + 0.75 * lit) * uLight;
  float dark = (rim * shade * 0.10 + fresnel * 0.07) * uLight;

  if (uMode > 1.5) {
    // 只画玻璃面：着色打底，亮边 / 面光是加白，暗线是加黑；预乘输出
    float a = uTint.a;
    vec3 col = uTint.rgb * a;
    float addW = clamp(rimLight + sheen * 0.07 * uLight, 0.0, 1.0); // 白色以 addW 的不透明度盖上去
    col = col * (1.0 - addW) + vec3(addW);
    a = a * (1.0 - addW) + addW;
    float addK = clamp(dark, 0.0, 1.0); // 黑色以 addK 的不透明度盖上去
    col *= 1.0 - addK;
    a = a * (1.0 - addK) + addK;
    fragColor = vec4(col, a) * aa;
    return;
  }

  float lens = pow(1.0 - depth, 2.0);
  vec3 col = sampleBg(p + n * uRefract * lens); // 边缘折射：像透镜一样把边缘外的画面往里弯
  float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = mix(vec3(luma), col, uSaturation);
  col = mix(col, uTint.rgb, uTint.a);
  col += rimLight;
  col -= dark;
  col += uLight * 0.07 * sheen;
  col = clamp(col, 0.0, 1.0);
  fragColor = vec4(col * aa, aa);
}
