#version 460 core
#include <flutter/runtime_effect.glsl>

// 玻璃：一份着色器两种用法。
//   uMode = 0：当 BackdropFilter 用（底栏这种真悬浮层，Impeller），纹理 = 它底下已模糊的画面。
//            纹理不是形状本身：它是「形状按模糊半径向四周外扩、再被屏幕裁掉」的那块（切页时整页套进透明度层则是整屏）。
//            靠 uOrigin / uRect / uScreen 反推纹理在屏幕上的位置，把形状定位回去——不然亮边/折射画在错的地方
//            （0.8.8 就是这样：胶囊两端各有一段白弧 + 黑弧，是外扩后的圆角画进了胶囊里）。
//            纹理尺寸 uSize 是像素还是逻辑 px 由引擎决定，按它和屏宽的比例自动识别（uDpr）。
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
uniform vec2 uScreen;      // 屏幕逻辑尺寸
uniform float uDpr;        // 设备像素比（mode 0 纹理若是物理像素要换算）
uniform sampler2D uBackdrop;

out vec4 fragColor;

float sdRoundRect(vec2 p, vec2 hs, float r) {
  vec2 d = abs(p) - (hs - vec2(r));
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// 形状局部坐标 q（逻辑 px）→ 纹理 uv：uv = gMin + q * gScale，两种模式在 main 里算好
vec2 gMin;
vec2 gScale;

vec3 sampleBg(vec2 q) {
  vec2 uv = clamp(gMin + q * gScale, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  if (uMode < 0.5) uv.y = 1.0 - uv.y;
#endif
  return texture(uBackdrop, uv).rgb;
}

void main() {
  vec2 rect = uRect;
  vec2 p;
  if (uMode < 0.5) {
    // 纹理单位：比屏宽还宽一大截就是物理像素
    float scale = uSize.x > 1.5 * uScreen.x ? max(uDpr, 1.0) : 1.0;
    vec2 tex = uSize / scale; // 纹理逻辑尺寸
    float texLeft;
    float texTop;
    if (tex.x > uScreen.x + 1.0) {
      // 纹理比屏幕还宽：外扩没被屏幕裁，四周对称
      float pad = (tex.x - uRect.x) * 0.5;
      texLeft = uOrigin.x - pad;
      texTop = uOrigin.y - pad;
    } else {
      // 被屏幕裁过：形状左右居中（底栏两边留白相等），纹理横向也居中
      texLeft = (uScreen.x - tex.x) * 0.5;
      // 纵向：先假设底边被裁（外扩量大于形状到底边的距离），不成立就按未裁（上下对称）算
      float bottomMargin = uScreen.y - (uOrigin.y + uRect.y);
      float padClipped = tex.y - (uScreen.y - uOrigin.y);
      float pad = padClipped >= bottomMargin ? padClipped : (tex.y - uRect.y) * 0.5;
      texTop = uOrigin.y - pad;
    }
    vec2 shapeInTex = uOrigin - vec2(texLeft, texTop); // 形状左上角在纹理里的逻辑坐标
    p = FlutterFragCoord().xy / scale - shapeInTex;
    gMin = shapeInTex / tex;
    gScale = 1.0 / tex;
  } else {
    p = FlutterFragCoord().xy;
    gMin = uOrigin / uSize;
    gScale = 1.0 / uSize;
  }
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
