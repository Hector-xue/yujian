#version 460 core
#include <flutter/runtime_effect.glsl>

// 玻璃：一份着色器两种用法。
//   uMode = 0：当 BackdropFilter 用（底栏这种真悬浮层，Impeller），纹理 = 它底下已模糊的画面，形状 = 整张纹理
//   uMode = 1：内容卡片对"预模糊的全局背景"按屏幕位置取样（背景静止，效果同真磨砂，每帧零回读）
// 质感来自四样：边缘折射（透镜把边缘外的画面往里弯）、饱和度、极淡的着色、沿光向的镜面亮边 + 背光暗边。

uniform vec2 uSize;        // 采样纹理尺寸（mode 0 由引擎填；mode 1 = 背景逻辑尺寸）
uniform vec2 uOrigin;      // 形状左上角在纹理坐标里的位置（mode 0 恒为 0）
uniform vec2 uRect;        // 形状尺寸（mode 1）
uniform float uRadius;     // 圆角
uniform float uMode;
uniform vec4 uTint;        // rgb + 着色强度（非预乘）
uniform float uSaturation; // 1 = 原样，1.5 ≈ iOS 材质
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
#ifdef IMPELLER_TARGET_OPENGLES
  if (uMode < 0.5) uv.y = 1.0 - uv.y;
#endif
  return texture(uBackdrop, uv).rgb;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 rect = uMode < 0.5 ? uSize : uRect;
  vec2 hs = rect * 0.5;
  float r = min(uRadius, min(hs.x, hs.y));
  vec2 c = p - hs;
  float sd = sdRoundRect(c, hs, r);
  // mode 0 的形状由外层 ClipRRect 切，这里不再切 alpha（纹理若比形状大一圈也不会缺角）
  float aa = uMode < 0.5 ? 1.0 : 1.0 - smoothstep(-0.8, 0.6, sd);
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
  float lens = pow(1.0 - depth, 2.0);

  vec3 col = sampleBg(p + n * uRefract * lens);
  float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = mix(vec3(luma), col, uSaturation);
  col = mix(col, uTint.rgb, uTint.a);

  vec2 L = normalize(vec2(-0.45, -0.89)); // 光从左上来
  float lit = max(dot(n, L), 0.0);
  float shade = max(dot(n, -L), 0.0);
  float rimW = 2.2;
  float rim = 1.0 - smoothstep(0.0, rimW, -sd); // 最外 2px：一圈细亮边，受光侧最亮，背光侧也留一点反光
  float fresnel = smoothstep(rimW, rimW + 1.5, -sd) * (1.0 - smoothstep(rimW + 1.5, rimW + 7.0, -sd)); // 亮边内侧一道极淡的暗线，玻璃才有厚度
  col += rim * (0.25 + 0.75 * lit) * uLight;
  col -= rim * shade * uLight * 0.10;
  col -= fresnel * uLight * 0.07;
  col += uLight * 0.07 * (1.0 - smoothstep(0.0, 0.6, p.y / rect.y)); // 顶部一道柔和面光
  col = clamp(col, 0.0, 1.0);
  fragColor = vec4(col * aa, aa);
}
