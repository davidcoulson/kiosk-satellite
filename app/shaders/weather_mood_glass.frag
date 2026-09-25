#version 460 core
#include <flutter/runtime_effect.glsl>
// A glass chip over the Weather Mood scene: frosted, lit softly from above,
// with a thin even rim and a faint bevel inside it.
uniform vec2 uSize;
// The chip in the backdrop's pixels: left, top, width, height.
uniform vec4 uRect;
// Darkening from Background opacity, 0 to 1.
uniform float uTint;
// Device pixels per logical pixel, so the effect keeps its size.
uniform float uScale;
uniform sampler2D uBackdrop;
out vec4 fragColor;

vec3 backdrop(vec2 pixel) {
  vec2 uv = clamp(pixel / uSize, vec2(0.), vec2(1.));
#ifdef IMPELLER_TARGET_OPENGLES
  // The input texture is stored upside down on OpenGL ES.
  uv.y = 1. - uv.y;
#endif
  return texture(uBackdrop, uv).rgb;
}

void main() {
  vec2 pixel = FlutterFragCoord().xy;
  // The engine may hand over only the clipped chip or the whole backdrop.
  bool cropped = abs(uSize.x - uRect.z) < 4. && abs(uSize.y - uRect.w) < 4.;
  vec2 origin = cropped ? vec2(0.) : uRect.xy;
  vec2 halfSize = uRect.zw * .5;
  vec2 center = origin + halfSize;
  float radius = halfSize.y;
  // Distance to the stadium's outline and the outward normal there.
  float spine = max(halfSize.x - radius, 0.);
  vec2 nearest = vec2(clamp(pixel.x, center.x - spine, center.x + spine), center.y);
  vec2 away = pixel - nearest;
  float reach = length(away);
  vec2 normal = reach > .001 ? away / reach : vec2(0., -1.);
  float depth = radius - reach;
  if (depth < 0.) {
    fragColor = vec4(backdrop(pixel), 1.);
    return;
  }
  // A slight inward pull at the rim, like the edge of a thick pane.
  float bevel = min(radius * .6, 14. * uScale);
  float rim = 1. - clamp(depth / bevel, 0., 1.);
  vec2 view = pixel - normal * rim * rim * bevel * .35;
  // Frosted: a soft blur of what is behind, two rings of taps.
  float near = 3. * uScale, far = 7. * uScale;
  vec3 color = backdrop(view) * .2;
  for (int i = 0; i < 8; i++) {
    float angle = float(i) * .7853982 + .3927;
    vec2 dir = vec2(cos(angle), sin(angle));
    color += backdrop(view + dir * near) * .06 + backdrop(view + dir * far) * .04;
  }
  // Tint for legibility, then a frosted lift, brighter toward the top.
  color = mix(color, vec3(.06, .07, .09), uTint * .62);
  float height = clamp((pixel.y - origin.y) / uRect.w, 0., 1.);
  color += vec3(.075) + vec3(.045) * (1. - smoothstep(0., .7, height));
  // An even rim, a touch brighter along the top and bottom, over a faint
  // bevel glow just inside it.
  float line = exp(-pow(depth / (1.7 * uScale), 2.));
  float inner = exp(-depth / (4.5 * uScale));
  float edge = .75 + .25 * abs(normal.y);
  color += vec3(1.) * (line * .36 + inner * .07) * edge;
  fragColor = vec4(clamp(color, 0., 1.), 1.);
}
