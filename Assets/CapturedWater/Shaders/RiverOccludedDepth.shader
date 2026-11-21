Shader "Hidden/River/Occluded Receiver Depth"
{
    Properties
    {
        [HideInInspector] _Cull("Culling", Float) = 2
        [HideInInspector] _BaseMap("Base Map", 2D) = "white" {}
        [HideInInspector] _BaseColor("Base Color", Color) = (1,1,1,1)
        [HideInInspector] _Cutoff("Alpha Cutoff", Range(0,1)) = 0.5
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/Shaders/LitInput.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthOnlyPass.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        float _Cull;

        float ReceiverEyeDepth(float deviceDepth)
        {
            return IsPerspectiveProjection() ? LinearEyeDepth(deviceDepth, _ZBufferParams) : LinearDepthToEyeDepth(deviceDepth);
        }

        half SubmergedDepth(Varyings input, float threshold, FRONT_FACE_TYPE facing)
        {
            // Only choose a surface its original forward material can actually shade.
            if (IS_FRONT_VFACE(facing, _Cull == 1, _Cull == 2)) discard;
            clip(ReceiverEyeDepth(input.positionCS.z) - threshold - max(0.0005, threshold * 1e-5));
            return DepthOnlyFragment(input);
        }
        ENDHLSL
        Pass
        {
            Name "Occluded Receiver Depth" Tags { "LightMode"="UniversalForward" }
            Cull Off ZWrite On ZTest LEqual ColorMask 0
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthOnlyVertex
            #pragma fragment OccludedDepthFrag
            #pragma multi_compile_instancing
            #pragma multi_compile_local _ _ALPHATEST_ON
            #pragma multi_compile_local_fragment _ _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
            #pragma multi_compile_fragment _ LOD_FADE_CROSSFADE
            TEXTURE2D_X_FLOAT(_RiverSurfaceDepth);

            half OccludedDepthFrag(Varyings input, FRONT_FACE_TYPE facing : FRONT_FACE_SEMANTIC) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                uint2 pixel = uint2(input.positionCS.xy);
                float water = LOAD_TEXTURE2D_X(_RiverSurfaceDepth, pixel).r;
                float front = LOAD_TEXTURE2D_X(_CameraDepthTexture, pixel).r;
                if (water == 0 || abs(front - UNITY_RAW_FAR_CLIP_VALUE) <= 1e-6) discard;
                float threshold = max(ReceiverEyeDepth(water), ReceiverEyeDepth(front));
                return SubmergedDepth(input, threshold, facing);
            }
            ENDHLSL
        }
        Pass
        {
            Name "Offscreen receiver depth" Tags { "LightMode"="RiverOffscreenReceiver" }
            Cull Off ZWrite On ZTest LEqual ColorMask 0
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthOnlyVertex
            #pragma fragment OffscreenDepthFrag
            #pragma multi_compile_instancing
            #pragma multi_compile_local _ _ALPHATEST_ON
            #pragma multi_compile_local_fragment _ _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
            #pragma multi_compile_fragment _ LOD_FADE_CROSSFADE
            TEXTURE2D_X_FLOAT(_RiverOffscreenWaterDepth);
            float4 _RiverOffscreenInterior;
            half OffscreenDepthFrag(Varyings input, FRONT_FACE_TYPE facing : FRONT_FACE_SEMANTIC) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float2 pixel = input.positionCS.xy;
                if (all(pixel > _RiverOffscreenInterior.xy) && all(pixel < _RiverOffscreenInterior.zw)) discard;
                float water = LOAD_TEXTURE2D_X(_RiverOffscreenWaterDepth, uint2(pixel)).r;
                if (water == 0) discard;
                return SubmergedDepth(input, ReceiverEyeDepth(water), facing);
            }
            ENDHLSL
        }
    }
}
