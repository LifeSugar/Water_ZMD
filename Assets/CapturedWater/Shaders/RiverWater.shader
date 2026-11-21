Shader "River/Flowing Water"
{
    Properties
    {
        [Header(Flow and ripples)]
        [NoScaleOffset] _FlowMap("River Flow (RG direction, B crests, A ripples)", 2D) = "gray" {}
        [NoScaleOffset] _WaveNormals("Packed Wave Normals", 2DArray) = "" {}
        _FlowSpeed("Flow Speed (metres per second)", Range(0, 8)) = 3.8
        _WaveTiling("Wave Tiling (repeats per metre)", Range(0.005, 0.5)) = 0.04
        _DetailTiling("Detail Tiling (repeats per metre)", Range(0.005, 0.5)) = 0.03
        _WaveStrength("Wave Normal Strength", Range(0, 2)) = 0.35
        _DetailStrength("Detail Normal Strength", Range(0, 2)) = 0.40
        [Enum(Primary,0,Alternate,1)] _DetailPattern("Detail Wave Pattern", Float) = 0
        [Header(Transmission and reflection)]
        [NoScaleOffset] _RiverbedDepth("Depth to Riverbed (0 to 18 metres)", 2D) = "gray" {}
        [MainColor] _DeepColor("Deep Water Colour", Color) = (0.22, 0.39, 0.34, 1)
        _TransmissionColor("Light Transmitted at Absorption Distance", Color) = (0.54, 0.79, 0.74, 1)
        _AbsorptionDistance("Absorption Distance (metres)", Range(0.15, 20)) = 2.5
        _RefractionStrength("Refraction Strength", Range(0, 1)) = 0.73
        _WaterlineDepth("Waterline Transition (metres)", Range(0.05, 2)) = 0.9
        _Smoothness("Surface Smoothness", Range(0, 1)) = 0.88
        _ReflectionDistance("Screen Reflection Distance (metres)", Range(0, 100)) = 32
        [Header(Shallows)]
        [NoScaleOffset] _CausticsMap("Caustic Pattern", 2D) = "black" {}
        _CausticsStrength("Caustic Strength", Range(0, 3)) = 0.85
        _FoamWidth("Shore Foam Width (metres of depth)", Range(0.02, 2)) = 0.32
        _FoamStrength("Foam Strength", Range(0, 1)) = 0.58
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Transparent" "Queue"="Transparent-50" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

        CBUFFER_START(UnityPerMaterial)
            half4 _DeepColor, _TransmissionColor;
            float _FlowSpeed, _WaveTiling, _DetailTiling, _WaveStrength, _DetailStrength, _DetailPattern;
            float _AbsorptionDistance, _RefractionStrength, _WaterlineDepth, _Smoothness, _ReflectionDistance;
            float _CausticsStrength, _FoamWidth, _FoamStrength;
        CBUFFER_END
        TEXTURE2D(_FlowMap); SAMPLER(sampler_FlowMap);
        TEXTURE2D_ARRAY(_WaveNormals); SAMPLER(sampler_WaveNormals);
        TEXTURE2D(_CausticsMap); SAMPLER(sampler_CausticsMap);
        TEXTURE2D(_RiverbedDepth); SAMPLER(sampler_RiverbedDepth);

        static const float MaxRefractionDepth = 18.0;
        // Alpha zero is the clear value. The remaining codes store the water column,
        // with finer precision at shallow depths where the distortion changes fastest.
        half PackWaterColumn(float normalizedDepth)
        {
            return (1.0 + 254.0 * sqrt(saturate(normalizedDepth))) / 255.0;
        }
        float WaterColumnMetres(half packed)
        {
            float depth = saturate((packed * 255.0 - 1.0) / 254.0);
            return MaxRefractionDepth * depth * depth;
        }
        float3 WorldAt(float2 uv, float deviceDepth)
        {
        #if !UNITY_REVERSED_Z
            deviceDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1, deviceDepth);
        #endif
            return ComputeWorldSpacePosition(uv, deviceDepth, UNITY_MATRIX_I_VP);
        }
        bool HasGeometry(float deviceDepth) { return abs(deviceDepth - UNITY_RAW_FAR_CLIP_VALUE) > 1e-6; }
        TEXTURE2D_X(_RiverSurfaceData);
        TEXTURE2D_X_FLOAT(_RiverSurfaceDepth);
        TEXTURE2D_X_FLOAT(_RiverOccludedDepth);
        TEXTURE2D_X(_RiverWaterlineMask);

        // R8 stores flags / 7. The low two bits classify the camera-visible surface.
        static const uint OutsideRiver = 0u, AboveWater = 1u, BelowWater = 2u, OpenWater = 3u;
        static const uint FrontClassBits = 3u, HasOccludedReceiver = 4u;

        struct Vertex { uint id:SV_VertexID; UNITY_VERTEX_INPUT_INSTANCE_ID };
        struct FullscreenPixel { float4 positionCS:SV_POSITION; UNITY_VERTEX_OUTPUT_STEREO };
        FullscreenPixel FullscreenVert(Vertex v)
        {
            UNITY_SETUP_INSTANCE_ID(v);
            FullscreenPixel o;
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
            o.positionCS = GetFullScreenTriangleVertexPosition(v.id);
            return o;
        }
        ENDHLSL

        Pass
        {
            Name "RiverSurface" Tags { "LightMode"="RiverSurfaceData" }
            Cull Off ZWrite On ZTest LEqual
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex SurfaceVert
            #pragma fragment SurfaceFrag
            #pragma multi_compile_instancing
            struct Attributes { float3 positionOS:POSITION; float3 normalOS:NORMAL; float2 flowUV:TEXCOORD0; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct Varyings { float4 positionCS:SV_POSITION; float3 positionWS:TEXCOORD0; half3 normalWS:TEXCOORD1; float2 flowUV:TEXCOORD2; UNITY_VERTEX_OUTPUT_STEREO };
            struct SurfaceTargets { half4 normalFoam:SV_Target0; float depth:SV_Target1; };

            Varyings SurfaceVert(Attributes v)
            {
                UNITY_SETUP_INSTANCE_ID(v);
                Varyings o;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.positionWS = TransformObjectToWorld(v.positionOS);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                o.normalWS = TransformObjectToWorldNormal(v.normalOS);
                o.flowUV = v.flowUV;
                return o;
            }

            half4 FlowingWaves(float2 position, float2 flow, float tiling, float cycle, float layer)
            {
                // Each sample has zero weight when its advection phase wraps.
                float phaseA = frac(cycle), phaseB = frac(cycle + 0.5);
                float2 baseUV = position * tiling;
                float2 travel = flow * (6.0 * tiling);
                half4 a = SAMPLE_TEXTURE2D_ARRAY(_WaveNormals, sampler_WaveNormals, baseUV - travel * phaseA, layer);
                half4 b = SAMPLE_TEXTURE2D_ARRAY(_WaveNormals, sampler_WaveNormals, baseUV - travel * phaseB + 0.5, layer);
                return lerp(b, a, 1.0 - abs(2.0 * phaseA - 1.0));
            }

            SurfaceTargets SurfaceFrag(Varyings i)
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                half4 flow = SAMPLE_TEXTURE2D(_FlowMap, sampler_FlowMap, i.flowUV);
                float2 direction = (flow.rg * 2.0 - 1.0) * float2(1, -1);
                float cycle = _Time.y * _FlowSpeed / 6.0;
                half4 wave = FlowingWaves(i.positionWS.xz, direction, _WaveTiling, cycle, 0);
                half4 detail = FlowingWaves(i.positionWS.xz, direction, _DetailTiling, cycle * 1.23 + 0.5, _DetailPattern);
                half2 slope = ((wave.rg * 2.0 - 1.0) * _WaveStrength +
                               (detail.rg * 2.0 - 1.0) * _DetailStrength) * lerp(0.2h, 1.0h, flow.a);
                half3 n = normalize(i.normalWS);
                half3 tangent = normalize(float3(1, 0, 0) - n * n.x);
                half3 normalWS = normalize(n + tangent * slope.x + cross(tangent, n) * slope.y);
                SurfaceTargets o;
                float depthToRiverbed = SAMPLE_TEXTURE2D(_RiverbedDepth, sampler_RiverbedDepth, i.flowUV).r;
                o.normalFoam = half4(PackNormalOctQuadEncode(normalWS) * 0.5 + 0.5,
                                      saturate(flow.b * max(0, wave.a - 0.05) * 1.5), PackWaterColumn(depthToRiverbed));
                // Keep the water plane behind an exposed object too. Both optical paths
                // can then tell which side of the local river surface an opaque sample is on.
                o.depth = i.positionCS.z;
                return o;
            }
            ENDHLSL
        }

        Pass
        {
            Name "RiverComposite" Tags { "LightMode"="RiverOptics" }
            Cull Off ZWrite On ZTest Always
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex FullscreenVert
            #pragma fragment CompositeFrag
            #pragma multi_compile_fragment _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            TEXTURE2D_X(_RiverOccludedColor);
            TEXTURE2D_X(_RiverOffscreenColor);
            TEXTURE2D_X_FLOAT(_RiverOffscreenDepth);
            TEXTURE2D_X_FLOAT(_RiverOffscreenWaterDepth);
            float4 _RiverOffscreenUV;
            struct WaterPixel { half4 color:SV_Target; float depth:SV_Depth; };

            uint WaterlineAt(float2 uv)
            {
                return (uint)round(7.0 * SAMPLE_TEXTURE2D_X_LOD(_RiverWaterlineMask, sampler_PointClamp, UnityStereoTransformScreenSpaceTex(uv), 0).r);
            }

            float SceneEyeDepth(float deviceDepth)
            {
                return IsPerspectiveProjection() ? LinearEyeDepth(deviceDepth, _ZBufferParams) : LinearDepthToEyeDepth(deviceDepth);
            }
            bool OnScreen(float2 uv) { return all(uv >= 0) && all(uv < 1); }
            // Only XY is widened. Device Z and WorldAt still use the main camera's projection.
            float2 OffscreenUV(float2 uv) { return uv * _RiverOffscreenUV.xy + _RiverOffscreenUV.zw; }
            bool InRefractionView(float2 uv)
            {
                return OnScreen(uv) || (_RiverOffscreenUV.x > 0 && OnScreen(OffscreenUV(uv)));
            }
            float3 RiverPlaneNormal(float3 surface)
            {
                float3 n = cross(ddx(surface), ddy(surface));
                float len2 = dot(n, n);
                return len2 > 1e-12 && n.y * n.y > 0.25 * len2
                    ? n * (n.y < 0 ? -rsqrt(len2) : rsqrt(len2)) : float3(0, 1, 0);
            }
            float RiverDepth(float2 uv)
            {
                return SAMPLE_TEXTURE2D_X_LOD(_RiverSurfaceDepth, sampler_PointClamp, UnityStereoTransformScreenSpaceTex(uv), 0).r;
            }
            static const float NoReceiver = 65504.0;
            float SignedImmersion(float waterDepth, float opaqueDepth, float planeScale)
            {
                if (!HasGeometry(opaqueDepth)) return NoReceiver;
                float waterEye = SceneEyeDepth(waterDepth);
                // Convert eye-depth separation along this ray to metres normal to the local river plane.
                float scale = IsPerspectiveProjection() ? planeScale / max(waterEye, 1e-5) : planeScale;
                return (SceneEyeDepth(opaqueDepth) - waterEye) * scale;
            }
            float OccludedDepth(float2 uv)
            {
                return SAMPLE_TEXTURE2D_X_LOD(_RiverOccludedDepth, sampler_PointClamp, UnityStereoTransformScreenSpaceTex(uv), 0).r;
            }
            float2 WaterInfo(float2 uv, float planeScale)
            {
                float depth = RiverDepth(uv);
                return float2(depth, SignedImmersion(depth, SampleSceneDepth(uv), planeScale));
            }
            static const uint NoSource = 0u, CameraSource = 1u, OccludedSource = 2u, OffscreenSource = 3u;
            static const uint HasOffscreenReceiver = 8u;

            uint RefractionFlags(float2 uv)
            {
                if (OnScreen(uv)) return WaterlineAt(uv);
                float2 extended = OffscreenUV(uv);
                if (_RiverOffscreenUV.x <= 0 || !OnScreen(extended)) return 0u;
                float depth = SAMPLE_TEXTURE2D_X_LOD(_RiverOffscreenDepth, sampler_PointClamp, extended, 0).r;
                return HasGeometry(depth) ? HasOffscreenReceiver : 0u;
            }

            uint RefractionSource(uint flags, bool deeper)
            {
                if ((flags & HasOffscreenReceiver) != 0) return deeper ? NoSource : OffscreenSource;
                if (!deeper && (flags & FrontClassBits) == BelowWater) return CameraSource;
                return (flags & HasOccludedReceiver) != 0 ? OccludedSource : NoSource;
            }
            float SourceDepth(float2 uv, uint source)
            {
                if (source == OffscreenSource)
                    return SAMPLE_TEXTURE2D_X_LOD(_RiverOffscreenDepth, sampler_PointClamp, OffscreenUV(uv), 0).r;
                return source == OccludedSource ? OccludedDepth(uv) : SampleSceneDepth(uv);
            }
            float SourceWaterDepth(float2 uv, uint source)
            {
                if (source == OffscreenSource)
                    return SAMPLE_TEXTURE2D_X_LOD(_RiverOffscreenWaterDepth, sampler_PointClamp, OffscreenUV(uv), 0).r;
                return RiverDepth(uv);
            }
            // x is the nearest submerged receiver, y is the peeled opaque layer.
            float2 ReceiverImmersions(float2 uv, uint flags, float planeScale)
            {
                float2 immersion = NoReceiver;
                uint source = RefractionSource(flags, false);
                if (source == NoSource) return immersion;
                if (source == OffscreenSource)
                {
                    immersion.x = SignedImmersion(SourceWaterDepth(uv, source), SourceDepth(uv, source), planeScale);
                    return immersion;
                }
                float water = RiverDepth(uv);
                if ((flags & HasOccludedReceiver) != 0)
                    immersion.y = SignedImmersion(water, OccludedDepth(uv), planeScale);
                immersion.x = source == CameraSource ? SignedImmersion(water, SampleSceneDepth(uv), planeScale) : immersion.y;
                return immersion;
            }
            int TraceSteps(float pixels, int limit) { return (int)clamp(ceil(pixels), 1, limit); }
            float ScreenStep(int i, int steps, float pixels)
            {
                float farPart = saturate((float)(i - 12) / max(1, steps - 12));
                return min(1.0, (i + max(0.0, pixels - steps) * farPart * farPart) / max(pixels, 1e-5));
            }
            bool HasImmersion(float immersion) { return immersion >= 0 && immersion < NoReceiver; }

            half3 InterfaceColor(float2 uv, float immersion)
            {
                float2 screenUV = UnityStereoTransformScreenSpaceTex(uv);
                // Near the contact only read the opaque texel whose depth was tested.
                if (abs(immersion) < 0.12)
                    return SAMPLE_TEXTURE2D_X_LOD(_CameraOpaqueTexture, sampler_PointClamp, screenUV, 0).rgb;
                return SAMPLE_TEXTURE2D_X_LOD(_CameraOpaqueTexture, sampler_LinearClamp, screenUV, 0).rgb;
            }

            bool CanFilterReceiver(float4 depths)
            {
                float low = min(min(depths.x, depths.y), min(depths.z, depths.w));
                float high = max(max(depths.x, depths.y), max(depths.z, depths.w));
            #if UNITY_REVERSED_Z
                float front = high, back = low;
            #else
                float front = low, back = high;
            #endif
                float nearest = SceneEyeDepth(front);
                return HasGeometry(back) && SceneEyeDepth(back) - nearest <= max(0.02, nearest * 0.025);
            }

            half3 TransmissionColor(float2 uv, float immersion, uint source)
            {
                if (source == OffscreenSource)
                {
                    float2 extended = OffscreenUV(uv);
                #ifdef PLATFORM_SUPPORT_GATHER
                    float4 depths = GATHER_TEXTURE2D_X(_RiverOffscreenDepth, sampler_PointClamp, extended);
                    if (immersion >= 0.12 && CanFilterReceiver(depths))
                        return SAMPLE_TEXTURE2D_X_LOD(_RiverOffscreenColor, sampler_LinearClamp, extended, 0).rgb;
                #endif
                    return SAMPLE_TEXTURE2D_X_LOD(_RiverOffscreenColor, sampler_PointClamp, extended, 0).rgb;
                }
                float2 screenUV = UnityStereoTransformScreenSpaceTex(uv);
                bool occluded = source == OccludedSource;
            #ifdef PLATFORM_SUPPORT_GATHER
                if (immersion >= 0.12)
                {
                    // Colour filtering must agree with the depth test. A dry foreground
                    // texel in the bilinear footprint would otherwise bleed into its neighbour.
                    uint4 flags = (uint4)round(7.0 * GATHER_TEXTURE2D_X(_RiverWaterlineMask, sampler_PointClamp, screenUV));
                    bool sameLayer = occluded ? all((flags & HasOccludedReceiver) != 0) : all((flags & FrontClassBits) == BelowWater);
                    float4 depths = occluded ? GATHER_TEXTURE2D_X(_RiverOccludedDepth, sampler_PointClamp, screenUV)
                                             : GATHER_TEXTURE2D_X(_CameraDepthTexture, sampler_PointClamp, screenUV);
                    if (sameLayer && CanFilterReceiver(depths))
                        return occluded ? SAMPLE_TEXTURE2D_X_LOD(_RiverOccludedColor, sampler_LinearClamp, screenUV, 0).rgb
                                        : SAMPLE_TEXTURE2D_X_LOD(_CameraOpaqueTexture, sampler_LinearClamp, screenUV, 0).rgb;
                }
            #endif
                return occluded ? SAMPLE_TEXTURE2D_X_LOD(_RiverOccludedColor, sampler_PointClamp, screenUV, 0).rgb
                                : SAMPLE_TEXTURE2D_X_LOD(_CameraOpaqueTexture, sampler_PointClamp, screenUV, 0).rgb;
            }

            // Convert a fraction of a projected screen segment to distance along its world-space ray.
            float RayFraction(float screenFraction, float startW, float endW)
            {
                return screenFraction * startW / max(lerp(endW, startW, screenFraction), 1e-5);
            }

            float TransmissionFraction(float immersion, float rayDepth)
            {
                float contact = smoothstep(0.35 * _WaterlineDepth, _WaterlineDepth, immersion);
                return lerp(saturate(immersion / max(rayDepth, 0.001)), 1.0, contact);
            }

            bool AtRiverbed(float2 uv, float immersion, float3 planeNormal)
            {
                float verticalDepth = immersion / max(planeNormal.y, 0.5);
                float3 overReceiver = WorldAt(uv, OccludedDepth(uv)) + float3(0, verticalDepth, 0);
                float2 surfaceUV = ComputeNormalizedDeviceCoordinates(overReceiver, UNITY_MATRIX_VP);
                if (!OnScreen(surfaceUV) || TransformWorldToHClip(overReceiver).w <= 0) return false;
                float packed = SAMPLE_TEXTURE2D_X_LOD(_RiverSurfaceData, sampler_PointClamp, UnityStereoTransformScreenSpaceTex(surfaceUV), 0).a;
                float surveyedDepth = WaterColumnMetres(packed);
                // Allow for bathymetry texel spacing and quantisation when matching the bed.
                return packed > 0 && abs(verticalDepth - surveyedDepth) <= 0.04 + 0.06 * surveyedDepth;
            }

            struct RefractionHit { float2 uv; uint source; };
            struct ScreenRay { float2 start, offset; float startW, endW, pixels, depth; };

            float ProjectedFraction(float t, ScreenRay ray)
            {
                return t * ray.endW / max(lerp(ray.startW, ray.endW, t), 1e-5);
            }

            float ImmersionAt(float2 uv, uint source, float planeScale)
            {
                if (source == NoSource) return NoReceiver;
                return SignedImmersion(SourceWaterDepth(uv, source), SourceDepth(uv, source), planeScale);
            }

            bool HitInSegment(ScreenRay ray, float lo, float hi, float priorGap, float gap, float immersion,
                              uint source, bool deeper, float planeScale, out RefractionHit hit)
            {
                hit.uv = ray.start + ray.offset * hi;
                hit.source = source;
                if (source == NoSource || !HasImmersion(immersion)) return false;
                if (hi == 1 && immersion >= _WaterlineDepth) return true;
                if (gap < 0 || priorGap >= 0) return false;

                [unroll] for (int j = 0; j < 5; ++j)
                {
                    float mid = (lo + hi) * 0.5;
                    float2 sampleUV = ray.start + ray.offset * mid;
                    uint sampleSource = RefractionSource(RefractionFlags(sampleUV), deeper);
                    float depth = ImmersionAt(sampleUV, sampleSource, planeScale);
                    if (HasImmersion(depth) && RayFraction(mid, ray.startW, ray.endW) >= TransmissionFraction(depth, ray.depth)) hi = mid;
                    else lo = mid;
                }
                hit.uv = ray.start + ray.offset * hi;
                hit.source = RefractionSource(RefractionFlags(hit.uv), deeper);
                float receiver = ImmersionAt(hit.uv, hit.source, planeScale);
                if (!HasImmersion(receiver)) return false;
                float expected = ProjectedFraction(TransmissionFraction(receiver, ray.depth), ray);
                return abs(hi - expected) * ray.pixels <= 1.25;
            }

            RefractionHit TraceRefraction(float2 uv, uint flags, float3 surface, float3 direction, float3 planeNormal,
                                          float planeScale, float column, float directImmersion)
            {
                RefractionHit miss;
                miss.uv = uv;
                miss.source = NoSource;
                RefractionHit origin = miss;
                origin.source = RefractionSource(flags, false);
                if (_RefractionStrength <= 0 || column <= 0.001) return origin;

                float travel = min(column / max(-direction.y, 0.12), MaxRefractionDepth);
                float3 endWS = surface + direction * travel;
                ScreenRay ray;
                ray.start = uv;
                ray.startW = TransformWorldToHClip(surface).w;
                ray.endW = TransformWorldToHClip(endWS).w;
                if (ray.endW <= 0) return miss;
                ray.offset = (ComputeNormalizedDeviceCoordinates(endWS, UNITY_MATRIX_VP) - uv) * _RefractionStrength;
                ray.pixels = max(abs(ray.offset.x) * _ScaledScreenParams.x, abs(ray.offset.y) * _ScaledScreenParams.y);
                ray.depth = max(-dot(direction, planeNormal), 0.12) * travel;

                float frontFraction = TransmissionFraction(directImmersion, ray.depth);
                if (origin.source != NoSource && ProjectedFraction(frontFraction, ray) * ray.pixels <= 0.5) return origin;
                uint deeperSource = RefractionSource(flags, true);
                float backFraction = TransmissionFraction(ImmersionAt(uv, deeperSource, planeScale), ray.depth);
                RefractionHit backHit = miss;
                if (deeperSource != NoSource && ProjectedFraction(backFraction, ray) * ray.pixels <= 0.5) backHit.source = deeperSource;

                float2 endUV = uv + ray.offset;
                bool coveredEnd = false;
                if (OnScreen(endUV))
                {
                    uint endClass = WaterlineAt(endUV) & FrontClassBits;
                    coveredEnd = endClass == AboveWater;
                    if (endClass == OutsideRiver)
                    {
                        float depth = SampleSceneDepth(endUV);
                        coveredEnd = HasGeometry(depth) && dot(WorldAt(endUV, depth) - surface, planeNormal) > 0;
                    }
                }

                // March the path once. A hit on the nearest submerged layer takes priority;
                // keep the peeled hit for rays that never intersect that layer.
                RefractionHit bankHit = miss;
                float closestBedGap = 2.0, previous = 0;
                float2 priorGap = -float2(frontFraction, backFraction);
                int steps = TraceSteps(ray.pixels, 32);
                [loop] for (int step = 1; step <= steps; ++step)
                {
                    float s = step == steps ? 1.0 : ScreenStep(step, steps, ray.pixels);
                    float2 tap = uv + ray.offset * s;
                    if (!InRefractionView(tap)) break;
                    if (!OnScreen(tap) && backHit.source != NoSource) return backHit;
                    uint tapFlags = RefractionFlags(tap);
                    float2 immersion = ReceiverImmersions(tap, tapFlags, planeScale);
                    float t = RayFraction(s, ray.startW, ray.endW);
                    float2 gap = float2(HasImmersion(immersion.x) ? t - TransmissionFraction(immersion.x, ray.depth) : -1,
                                        HasImmersion(immersion.y) ? t - TransmissionFraction(immersion.y, ray.depth) : -1);
                    RefractionHit candidate;
                    if (HitInSegment(ray, previous, s, priorGap.x, gap.x, immersion.x,
                                     RefractionSource(tapFlags, false), false, planeScale, candidate)) return candidate;
                    if (backHit.source == NoSource && (tapFlags & HasOccludedReceiver) != 0)
                    {
                        if (HitInSegment(ray, previous, s, priorGap.y, gap.y, immersion.y, OccludedSource, true, planeScale, candidate))
                            backHit = candidate;
                        else if (coveredEnd && (tapFlags & FrontClassBits) == AboveWater && HasImmersion(immersion.y) &&
                                 abs(gap.y) < closestBedGap && AtRiverbed(tap, immersion.y, planeNormal))
                        {
                            closestBedGap = abs(gap.y);
                            bankHit.uv = tap;
                            bankHit.source = OccludedSource;
                        }
                    }
                    previous = s;
                    priorGap = gap;
                }
                if (backHit.source != NoSource) return backHit;
                return bankHit;
            }

            float AirDepth(float2 uv, float3 surface, float3 planeNormal)
            {
                uint front = WaterlineAt(uv) & FrontClassBits;
                if (front == AboveWater) return SampleSceneDepth(uv);
                if (front != OutsideRiver) return UNITY_RAW_FAR_CLIP_VALUE;
                // Land beyond the water mesh can still reflect in the local river plane.
                float depth = SampleSceneDepth(uv);
                return HasGeometry(depth) && dot(WorldAt(uv, depth) - surface, planeNormal) >= -0.005 ? depth : UNITY_RAW_FAR_CLIP_VALUE;
            }

            float3 OpaqueAtPixel(float2 uv)
            {
                return WorldAt(uv, SampleSceneDepth(uv));
            }

            bool ContactMirrorHit(float2 sampleUV, float3 surface, float3 planeNormal, float3 direction,
                                  float range, out float2 hitUV)
            {
                float2 size = _ScaledScreenParams.xy;
                float2 center = (floor(sampleUV * size) + 0.5) / size;
                float3 source = OpaqueAtPixel(center);
                float2 dx = float2(1.0 / size.x, 0), dy = float2(0, 1.0 / size.y);
                float3 right = OpaqueAtPixel(center + dx) - source, left = source - OpaqueAtPixel(center - dx);
                float3 up = OpaqueAtPixel(center + dy) - source, down = source - OpaqueAtPixel(center - dy);
                // Choose neighbours on the foreground surface at a discontinuity. Its local
                // plane lets a curved silhouette intersect between two depth samples.
                float3 tangentX = dot(right, right) < dot(left, left) ? right : left;
                float3 tangentY = dot(up, up) < dot(down, down) ? up : down;
                float3 objectNormal = cross(tangentX, tangentY);
                float denominator = dot(objectNormal, direction);
                hitUV = center;
                if (abs(denominator) < 1e-10) return false;
                float travel = dot(objectNormal, source - surface) / denominator;
                if (travel <= 0 || travel > range) return false;
                float3 contact = surface + direction * travel;
                if (dot(contact - surface, planeNormal) < 0) return false;
                hitUV = ComputeNormalizedDeviceCoordinates(contact, UNITY_MATRIX_VP);
                return all(abs((hitUV - center) * size) <= 0.5);
            }

            half3 ReflectedScene(float3 surface, half3 normal, float3 planeNormal, float planeScale, half3 view, half fog)
            {
                half3 direction = reflect(-view, normal);
                half mip = PerceptualRoughnessToMipmapLevel(1 - _Smoothness);
                half4 sky = SAMPLE_TEXTURECUBE_LOD(_GlossyEnvironmentCubeMap, sampler_GlossyEnvironmentCubeMap, direction, mip);
                half3 environment = MixFog(DecodeHDREnvironment(sky, _GlossyEnvironmentCubeMap_HDR), fog);
                if (_ReflectionDistance <= 0) return environment;

                float3 origin = surface;
                float range = _ReflectionDistance;
                float3 endWS = origin + direction * range;
                float startEye = -TransformWorldToView(origin).z, endEye = -TransformWorldToView(endWS).z;
                if (endEye <= _ProjectionParams.y)
                {
                    range *= saturate((startEye - _ProjectionParams.y * 1.01) / max(startEye - endEye, 1e-5));
                    endWS = origin + direction * range;
                    endEye = -TransformWorldToView(endWS).z;
                }
                float2 startUV = ComputeNormalizedDeviceCoordinates(origin, UNITY_MATRIX_VP);
                float2 deltaUV = ComputeNormalizedDeviceCoordinates(endWS, UNITY_MATRIX_VP) - startUV;
                float2 edge = lerp(startUV, 1 - startUV, step(0, deltaUV));
                float2 edgeFraction = edge / max(abs(deltaUV), 1e-6);
                float sEnd = min(1.0, min(edgeFraction.x, edgeFraction.y));
                float startW = TransformWorldToHClip(origin).w, endW = TransformWorldToHClip(endWS).w;
                float span = max(abs(deltaUV.x) * _ScaledScreenParams.x, abs(deltaUV.y) * _ScaledScreenParams.y) * sEnd;
                int steps = TraceSteps(span, 56);
                float previous = 0;
                float previousGap = -1e-4;
                [loop] for (int i = 1; i <= steps; ++i)
                {
                    // Start at the next pixel. A world-space bias or a long first step skips low caps.
                    float s = ScreenStep(i, steps, span) * sEnd;
                    float2 uv = startUV + deltaUV * s;
                    float eye = lerp(startEye, endEye, RayFraction(s, startW, endW));
                    float raw = AirDepth(uv, surface, planeNormal);
                    float gap = eye - SceneEyeDepth(raw);
                    if (gap >= 0 && previousGap < 0)
                    {
                        float lo = previous, hi = s;
                        [unroll] for (int j = 0; j < 4; ++j)
                        {
                            float mid = 0.5 * (lo + hi);
                            float midEye = lerp(startEye, endEye, RayFraction(mid, startW, endW));
                            if (midEye >= SceneEyeDepth(AirDepth(startUV + deltaUV * mid, surface, planeNormal))) hi = mid;
                            else lo = mid;
                        }
                        float2 hitUV = startUV + deltaUV * hi;
                        float t = RayFraction(hi, startW, endW);
                        float separation = lerp(startEye, endEye, t) - SceneEyeDepth(AirDepth(hitUV, surface, planeNormal));
                        float2 hitRiver = WaterInfo(hitUV, planeScale);
                        bool valid = separation >= -0.001 && separation <= max(0.08, eye * 0.018);
                        if (valid && hitRiver.x > 0 && -hitRiver.y < 0.20)
                        {
                            float2 contactUV;
                            valid = ContactMirrorHit(hitUV, surface, planeNormal, direction, range, contactUV);
                            if (valid) hitUV = contactUV;
                        }
                        if (valid)
                        {
                            float2 border = min(hitUV, 1 - hitUV);
                            float confidence = saturate(min(border.x, border.y) * 32) * saturate((1 - t) * 8);
                            return lerp(environment, InterfaceColor(hitUV, hitRiver.y), confidence);
                        }
                    }
                    // A tangent hit on a round cap can touch a pixel without crossing its
                    // front depth. Check whether the visible source mirrors back to this pixel.
                    if (i <= 24 && gap < 0 && HasGeometry(raw) && abs(gap) < max(0.18, eye * 0.025))
                    {
                        float2 river = WaterInfo(uv, planeScale);
                        float2 contactUV;
                        if (river.x > 0 && -river.y < 0.2 && ContactMirrorHit(uv, surface, planeNormal, direction, range, contactUV))
                            return InterfaceColor(contactUV, river.y);
                    }
                    previous = s;
                    previousGap = gap;
                }
                return environment;
            }

            WaterPixel CompositeFrag(FullscreenPixel i)
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                uint2 pixel = uint2(i.positionCS.xy);
                half4 data = LOAD_TEXTURE2D_X(_RiverSurfaceData, pixel);
                float waterDepth = LOAD_TEXTURE2D_X(_RiverSurfaceDepth, pixel).r;
                float2 uv = GetNormalizedScreenSpaceUV(i.positionCS);
                float3 surface = WorldAt(uv, waterDepth);
                float3 planeNormal = RiverPlaneNormal(surface);
                uint flags = (uint)round(7.0 * LOAD_TEXTURE2D_X(_RiverWaterlineMask, pixel).r);
                uint front = flags & FrontClassBits;
                if (front != BelowWater && front != OpenWater) discard;
                float directDepth = SampleSceneDepth(uv);
                half fog = ComputeFogFactorZ0ToFar(max(0, SceneEyeDepth(waterDepth) - _ProjectionParams.y));
                float planeScale = IsPerspectiveProjection() ? abs(dot(GetCameraPositionWS() - surface, planeNormal))
                                                             : abs(dot(GetViewForwardDir(), planeNormal));
                float directImmersion = SignedImmersion(waterDepth, directDepth, planeScale);
                half3 normal = UnpackNormalOctQuadEncode(data.rg * 2 - 1);
                // Anchor the micro-normal at the contact line. Its reflection must meet
                // the exposed silhouette even when only a few millimetres break the water.
                normal = normalize(lerp(planeNormal, normal, smoothstep(0.0, 0.15 * _WaterlineDepth, directImmersion)));
                half3 view = GetWorldSpaceNormalizeViewDir(surface);
                half3 facingNormal = dot(normal, view) >= 0 ? normal : -normal;
                Light sun = GetMainLight(TransformWorldToShadowCoord(surface));
                half3 direct = sun.color * sun.shadowAttenuation;

                float3 ray = refract(-view, facingNormal, 1.0 / 1.333);
                float column = WaterColumnMetres(data.a);
                RefractionHit hit = TraceRefraction(uv, flags, surface, ray, planeNormal, planeScale, column, directImmersion);
                bool hasBed = hit.source != NoSource;
                float opaqueDepth = hasBed ? SourceDepth(hit.uv, hit.source) : UNITY_RAW_FAR_CLIP_VALUE;
                float3 bed = hasBed ? WorldAt(hit.uv, opaqueDepth) : surface;
                float verticalDepth = hasBed ? max(0, SignedImmersion(SourceWaterDepth(hit.uv, hit.source), opaqueDepth, planeScale)) : 60;
                float thickness = min(distance(surface, bed), 60.0);
                half3 transmission = hasBed ? exp(log(clamp(_TransmissionColor.rgb, 0.001, 1.0)) * (thickness / _AbsorptionDistance)) : 0;
                float waterTime = _Time.y * _FlowSpeed;
                float2 causticUV = bed.xz * 0.27;
                half causticA = SAMPLE_TEXTURE2D(_CausticsMap, sampler_CausticsMap, causticUV + waterTime * float2(0.014, -0.011)).r;
                half causticB = SAMPLE_TEXTURE2D(_CausticsMap, sampler_CausticsMap, causticUV.yx * 1.19 + waterTime * 0.009).r;
                half caustic = min(causticA, causticB) * 6 * _CausticsStrength * exp(-verticalDepth * 0.9);
                half3 bottom = 0;
                if (hasBed)
                {
                    half3 receiverColor = TransmissionColor(hit.uv, verticalDepth, hit.source);
                    bottom = receiverColor * (1 + caustic * direct * saturate(sun.direction.y));
                }
                half3 scatter = MixFog(_DeepColor.rgb * (unity_AmbientSky.rgb + 0.35 * direct * saturate(sun.direction.y)), fog);
                half3 transmitted = lerp(scatter, bottom, transmission);

                half nDotV = saturate(dot(facingNormal, view));
                half grazing = 1 - nDotV;
                half grazing2 = grazing * grazing;
                half fresnel = 0.0204 + 0.9796 * grazing2 * grazing2 * grazing;
                half3 reflected = ReflectedScene(surface, facingNormal, planeNormal, planeScale, view, fog);
                half nDotH = saturate(dot(facingNormal, SafeNormalize(view + sun.direction)));
                half sunGlint = pow(nDotH, exp2(5 + 6 * _Smoothness)) * saturate(dot(facingNormal, sun.direction));
                half3 color = lerp(transmitted, reflected, fresnel) + MixFogColor(direct * sunGlint * 0.7, half3(0,0,0), fog);
                half shoreline = 1 - smoothstep(0.0, _FoamWidth, verticalDepth);
                half foam = saturate((shoreline * (0.22 + 0.78 * causticA) + data.b) * _FoamStrength);
                half3 foamColor = 0.78 * (unity_AmbientSky.rgb + direct * saturate(dot(facingNormal, sun.direction)));
                color = lerp(color, MixFog(foamColor, fog), foam);
                WaterPixel o;
                o.color = half4(color, 1);
                o.depth = waterDepth;
                return o;
            }
            ENDHLSL
        }

        Pass
        {
            Name "RiverWaterline" Tags { "LightMode"="RiverWaterline" }
            Cull Off ZWrite Off ZTest Always
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex FullscreenVert
            #pragma fragment WaterlineFrag
            float WaterlineFrag(FullscreenPixel i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                uint2 pixel = uint2(i.positionCS.xy);
                if (LOAD_TEXTURE2D_X(_RiverSurfaceData, pixel).a == 0) return 0;
                float opaque = LOAD_TEXTURE2D_X(_CameraDepthTexture, pixel).r;
                if (!HasGeometry(opaque)) return OpenWater / 7.0;
                float water = LOAD_TEXTURE2D_X(_RiverSurfaceDepth, pixel).r;
            #if UNITY_REVERSED_Z
                bool above = opaque > water;
            #else
                bool above = opaque < water;
            #endif
                uint flags = above ? AboveWater : BelowWater;
                if (HasGeometry(LOAD_TEXTURE2D_X(_RiverOccludedDepth, pixel).r)) flags |= HasOccludedReceiver;
                return flags / 7.0;
            }
            ENDHLSL
        }
        Pass
        {
            Name "RiverOffscreenWaterDepth" Tags { "LightMode"="RiverOffscreenWaterDepth" }
            Cull Off ZWrite On ZTest LEqual
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex WaterDepthVert
            #pragma fragment WaterDepthFrag
            #pragma multi_compile_instancing
            struct WaterVertex { float3 positionOS : POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
            float4 WaterDepthVert(WaterVertex v) : SV_POSITION
            {
                UNITY_SETUP_INSTANCE_ID(v);
                return TransformObjectToHClip(v.positionOS);
            }
            float WaterDepthFrag(float4 positionCS : SV_POSITION) : SV_Target { return positionCS.z; }
            ENDHLSL
        }
    }
    Dependency "OccludedReceiverDepth" = "Hidden/River/Occluded Receiver Depth"
}
