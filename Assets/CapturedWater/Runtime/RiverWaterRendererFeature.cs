using System.Collections.Generic;
using Unity.Collections;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace CapturedWater
{
    public sealed class RiverWaterRendererFeature : ScriptableRendererFeature
    {
        [Tooltip("The river material supplies the optical properties for the full-screen water pass.")]
        public Material waterMaterial;

        static readonly int SurfaceDataId = Shader.PropertyToID("_RiverSurfaceData");
        static readonly int SurfaceDepthId = Shader.PropertyToID("_RiverSurfaceDepth");
        static readonly int OccludedDepthId = Shader.PropertyToID("_RiverOccludedDepth");
        static readonly int WaterlineMaskId = Shader.PropertyToID("_RiverWaterlineMask");
        static class PassTags
        {
            public static readonly ShaderTagId Surface = new ShaderTagId("RiverSurfaceData");
            public static readonly ShaderTagId OffscreenWaterDepth = new ShaderTagId("RiverOffscreenWaterDepth");
            public static readonly ShaderTagId Forward = new ShaderTagId("UniversalForward");
            public static readonly ShaderTagId ForwardOnly = new ShaderTagId("UniversalForwardOnly");
            public static readonly ShaderTagId Unlit = new ShaderTagId("SRPDefaultUnlit");
        }
        static readonly int RefractionStrengthId = Shader.PropertyToID("_RefractionStrength");
        SurfacePass surface;
        OccludedReceiversPass receivers;
        OffscreenReceiversPass offscreen;
        WaterlinePass waterline;
        CompositePass composite;

        public override void Create()
        {
            surface?.Release();
            receivers?.Release();
            offscreen?.Release();
            waterline?.Release();
            surface = new SurfacePass();
            receivers = new OccludedReceiversPass(surface);
            offscreen = new OffscreenReceiversPass();
            waterline = new WaterlinePass(surface, receivers);
            composite = new CompositePass(surface, receivers, waterline, offscreen);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData data)
        {
            if (!waterMaterial || data.cameraData.isPreviewCamera ||
                data.cameraData.renderType == CameraRenderType.Overlay) return;

            composite.material = waterMaterial;
            renderer.EnqueuePass(surface);
            receivers.depthShader = waterMaterial.shader.GetDependency("OccludedReceiverDepth");
            renderer.EnqueuePass(receivers);
            waterline.material = waterMaterial;
            waterline.passIndex = waterMaterial.FindPass("RiverWaterline");
            if (waterline.passIndex >= 0) renderer.EnqueuePass(waterline);
            offscreen.ready = false;
            offscreen.depthShader = receivers.depthShader;
            if (!data.cameraData.camera.stereoEnabled && offscreen.depthShader && offscreen.depthShader.passCount > 1 &&
                waterMaterial.HasProperty(RefractionStrengthId) && waterMaterial.GetFloat(RefractionStrengthId) > 0 &&
                waterMaterial.FindPass("RiverOffscreenWaterDepth") >= 0)
                renderer.EnqueuePass(offscreen);
            renderer.EnqueuePass(composite);
        }

        protected override void Dispose(bool disposing)
        {
            surface?.Release();
            receivers?.Release();
            offscreen?.Release();
            waterline?.Release();
        }

        static void BindDepthInputs(CommandBuffer cmd, SurfacePass surface, OccludedReceiversPass receivers)
        {
            cmd.SetGlobalTexture(SurfaceDataId, surface.SurfaceData.nameID);
            cmd.SetGlobalTexture(SurfaceDepthId, surface.SurfaceDepth.nameID);
            cmd.SetGlobalTexture(OccludedDepthId, receivers.ReceiverDepth.nameID);
        }

        sealed class SurfacePass : ScriptableRenderPass
        {
            readonly RTHandle[] colors = new RTHandle[2];
            FilteringSettings waterRenderers = new FilteringSettings(RenderQueueRange.transparent);
            RTHandle surfaceDepthTest;

            public RTHandle SurfaceData => colors[0];
            public RTHandle SurfaceDepth => colors[1];

            public SurfacePass()
            {
                profilingSampler = new ProfilingSampler("River / surface normals and depth");
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
                ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Color);
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData data)
            {
                var desc = data.cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1;
                desc.bindMS = false;
                desc.useMipMap = desc.autoGenerateMips = false;
                desc.depthStencilFormat = GraphicsFormat.None;
                desc.graphicsFormat = GraphicsFormat.R8G8B8A8_UNorm;
                RenderingUtils.ReAllocateIfNeeded(ref colors[0], desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverSurfaceData");
                desc.graphicsFormat = GraphicsFormat.R32_SFloat;
                RenderingUtils.ReAllocateIfNeeded(ref colors[1], desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverSurfaceDepth");
                desc.graphicsFormat = GraphicsFormat.None;
                desc.depthStencilFormat = GraphicsFormat.D32_SFloat;
                RenderingUtils.ReAllocateIfNeeded(ref surfaceDepthTest, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "River surface depth test");
                ConfigureTarget(colors, surfaceDepthTest);
                ConfigureClear(ClearFlag.All, Color.clear);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData data)
            {
                var draw = CreateDrawingSettings(PassTags.Surface, ref data, SortingCriteria.CommonOpaque);
                context.DrawRenderers(data.cullResults, ref draw, ref waterRenderers);
            }

            public void Release()
            {
                colors[0]?.Release();
                colors[1]?.Release();
                surfaceDepthTest?.Release();
            }
        }

        // Preserve the first submerged surface behind the front opaque layer. Use the
        // objects' own forward passes for its colour, including their textures and shadows.
        sealed class OccludedReceiversPass : ScriptableRenderPass
        {
            readonly SurfacePass surface;
            FilteringSettings opaque = new FilteringSettings(RenderQueueRange.opaque);
            RenderStateBlock shadeRecordedDepth = new RenderStateBlock(RenderStateMask.Depth)
                { depthState = new DepthState(false, CompareFunction.Equal) };
            RTHandle color, depth;
            public RTHandle ReceiverColor => color;
            public RTHandle ReceiverDepth => depth;
            public Shader depthShader;

            public OccludedReceiversPass(SurfacePass surface)
            {
                this.surface = surface;
                profilingSampler = new ProfilingSampler("River / occluded underwater receivers");
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData data)
            {
                var desc = data.cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1;
                desc.bindMS = false;
                desc.useMipMap = desc.autoGenerateMips = false;
                desc.memoryless = RenderTextureMemoryless.None;
                desc.depthStencilFormat = GraphicsFormat.None;
                RenderingUtils.ReAllocateIfNeeded(ref color, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverOccludedColor");
                desc.graphicsFormat = GraphicsFormat.None;
                desc.depthStencilFormat = GraphicsFormat.D32_SFloat;
                RenderingUtils.ReAllocateIfNeeded(ref depth, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverOccludedDepth");
                ConfigureTarget(color, depth);
                ConfigureClear(ClearFlag.All, Color.clear);
                ConfigureColorStoreAction(RenderBufferStoreAction.Store);
                ConfigureDepthStoreAction(RenderBufferStoreAction.Store);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData data)
            {
                if (!depthShader) return;
                var cmd = CommandBufferPool.Get();
                cmd.SetGlobalTexture(SurfaceDepthId, surface.SurfaceDepth.nameID);
                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);

                var shade = CreateDrawingSettings(PassTags.Forward, ref data, data.cameraData.defaultOpaqueSortFlags);
                DrawReceivers(context, data.cullResults, shade, depthShader, 0, ref opaque, ref shadeRecordedDepth);
            }

            public void Release()
            {
                color?.Release();
                depth?.Release();
            }
        }

        static void DrawReceivers(ScriptableRenderContext context, CullingResults culling, DrawingSettings shade,
                                  Shader depthShader, int depthPass, ref FilteringSettings opaque, ref RenderStateBlock shadeDepth)
        {
            shade.SetShaderPassName(1, PassTags.ForwardOnly);
            shade.SetShaderPassName(2, PassTags.Unlit);
            var peel = shade;
            peel.overrideShader = depthShader;
            peel.overrideShaderPassIndex = depthPass;
            context.DrawRenderers(culling, ref peel, ref opaque);
            context.DrawRenderers(culling, ref shade, ref opaque, ref shadeDepth);
        }

        // Extend the available scene for rays leaving the image. The main camera and its
        // full-resolution colour, depth and waterline mask keep their original viewport.
        sealed class OffscreenReceiversPass : ScriptableRenderPass
        {
            // The central 40% of the extended projection is the camera image.
            const float CameraFraction = 0.4f;
            const float Inset = (1 - CameraFraction) * 0.5f;
            static readonly int UvId = Shader.PropertyToID("_RiverOffscreenUV");
            static readonly int ColorId = Shader.PropertyToID("_RiverOffscreenColor");
            static readonly int DepthId = Shader.PropertyToID("_RiverOffscreenDepth");
            static readonly int WaterId = Shader.PropertyToID("_RiverOffscreenWaterDepth");
            static readonly int InteriorId = Shader.PropertyToID("_RiverOffscreenInterior");
            readonly Plane[] planes = new Plane[6];
            readonly Dictionary<Light, int> cameraLightIndices = new Dictionary<Light, int>();
            RTHandle waterDepth, color, depth;
            FilteringSettings water = new FilteringSettings(RenderQueueRange.transparent);
            FilteringSettings opaque = new FilteringSettings(RenderQueueRange.opaque);
            RenderStateBlock shadeDepth = new RenderStateBlock(RenderStateMask.Depth)
                { depthState = new DepthState(false, CompareFunction.Equal) };
            public Shader depthShader;
            public bool ready;

            public OffscreenReceiversPass()
            {
                profilingSampler = new ProfilingSampler("River / offscreen refraction sources");
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData data)
            {
                var desc = data.cameraData.cameraTargetDescriptor;
                desc.width = (desc.width + 1) / 2;
                desc.height = (desc.height + 1) / 2;
                desc.useDynamicScale = false;
                desc.msaaSamples = 1;
                desc.bindMS = false;
                desc.useMipMap = desc.autoGenerateMips = false;
                desc.memoryless = RenderTextureMemoryless.None;
                desc.depthStencilFormat = GraphicsFormat.None;
                RenderingUtils.ReAllocateIfNeeded(ref color, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverOffscreenColor");
                desc.graphicsFormat = GraphicsFormat.R32_SFloat;
                RenderingUtils.ReAllocateIfNeeded(ref waterDepth, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverOffscreenWaterDepth");
                desc.graphicsFormat = GraphicsFormat.None;
                desc.depthStencilFormat = GraphicsFormat.D32_SFloat;
                RenderingUtils.ReAllocateIfNeeded(ref depth, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverOffscreenDepth");
                ConfigureTarget(waterDepth, depth);
                ConfigureClear(ClearFlag.All, Color.clear);
                ConfigureColorStoreAction(RenderBufferStoreAction.Store);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData data)
            {
                ref var camera = ref data.cameraData;
                if (!camera.camera.TryGetCullingParameters(out var parameters)) return;
                var projection = camera.GetProjectionMatrix();
                projection.SetRow(0, projection.GetRow(0) * CameraFraction);
                projection.SetRow(1, projection.GetRow(1) * CameraFraction);
                var view = camera.GetViewMatrix();
                parameters.cullingMatrix = projection * view;
                GeometryUtility.CalculateFrustumPlanes(parameters.cullingMatrix, planes);
                parameters.cullingPlaneCount = planes.Length;
                for (int i = 0; i < planes.Length; ++i) parameters.SetCullingPlane(i, planes[i]);
                parameters.cullingOptions &= ~(CullingOptions.OcclusionCull | CullingOptions.ShadowCasters);
                var culling = context.Cull(ref parameters);
                if (data.lightData.additionalLightsCount > 0) MatchCameraLights(data.cullResults, culling);

                var cmd = CommandBufferPool.Get();
                cmd.SetViewProjectionMatrices(view, projection);
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();
                var drawWater = CreateDrawingSettings(PassTags.OffscreenWaterDepth, ref data, SortingCriteria.CommonOpaque);
                context.DrawRenderers(culling, ref drawWater, ref water);

                // Keep one texel inside the camera image for filtering across its border.
                CoreUtils.SetRenderTarget(cmd, color, depth, ClearFlag.All, Color.clear);
                cmd.SetGlobalTexture(WaterId, waterDepth.nameID);
                float width = waterDepth.rt.width, height = waterDepth.rt.height;
                cmd.SetGlobalVector(InteriorId, new Vector4(width * Inset + 1, height * Inset + 1,
                                                           width * (1 - Inset) - 1, height * (1 - Inset) - 1));
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();
                var shade = CreateDrawingSettings(PassTags.Forward, ref data, data.cameraData.defaultOpaqueSortFlags);
                DrawReceivers(context, culling, shade, depthShader, 1, ref opaque, ref shadeDepth);
                ScriptableRenderer.SetCameraMatrices(cmd, ref camera, true);
                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);
                ready = true;
            }

            // The forward materials use the light buffer URP already uploaded for the camera.
            void MatchCameraLights(CullingResults camera, CullingResults extended)
            {
                cameraLightIndices.Clear();
                var cameraLights = camera.visibleLights;
                var cameraIndices = camera.GetLightIndexMap(Allocator.Temp);
                for (int i = 0; i < cameraLights.Length; ++i)
                    if (cameraLights[i].light) cameraLightIndices[cameraLights[i].light] = cameraIndices[i];
                cameraIndices.Dispose();

                var lights = extended.visibleLights;
                var indices = extended.GetLightIndexMap(Allocator.Temp);
                for (int i = 0; i < lights.Length; ++i)
                    indices[i] = lights[i].light && cameraLightIndices.TryGetValue(lights[i].light, out var index) ? index : -1;
                extended.SetLightIndexMap(indices);
                indices.Dispose();
            }

            public void Bind(CommandBuffer cmd)
            {
                cmd.SetGlobalVector(UvId, ready ? new Vector4(CameraFraction, CameraFraction, Inset, Inset) : Vector4.zero);
                if (!ready) return;
                cmd.SetGlobalTexture(WaterId, waterDepth.nameID);
                cmd.SetGlobalTexture(ColorId, color.nameID);
                cmd.SetGlobalTexture(DepthId, depth.nameID);
            }

            public void Release()
            {
                waterDepth?.Release();
                color?.Release();
                depth?.Release();
            }
        }

        sealed class WaterlinePass : ScriptableRenderPass
        {
            readonly SurfacePass surface;
            readonly OccludedReceiversPass receivers;
            RTHandle mask;
            public RTHandle Mask => mask;
            public Material material;
            public int passIndex;

            public WaterlinePass(SurfacePass surface, OccludedReceiversPass receivers)
            {
                this.surface = surface;
                this.receivers = receivers;
                profilingSampler = new ProfilingSampler("River / waterline mask");
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData data)
            {
                var desc = data.cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1;
                desc.bindMS = false;
                desc.useMipMap = desc.autoGenerateMips = false;
                desc.memoryless = RenderTextureMemoryless.None;
                desc.depthStencilFormat = GraphicsFormat.None;
                desc.graphicsFormat = GraphicsFormat.R8_UNorm;
                RenderingUtils.ReAllocateIfNeeded(ref mask, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RiverWaterlineMask");
                ConfigureTarget(mask);
                ConfigureClear(ClearFlag.None, Color.clear);
                ConfigureColorStoreAction(RenderBufferStoreAction.Store);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData data)
            {
                var cmd = CommandBufferPool.Get();
                BindDepthInputs(cmd, surface, receivers);
                cmd.DrawProcedural(Matrix4x4.identity, material, passIndex, MeshTopology.Triangles, 3);
                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);
            }

            public void Release() => mask?.Release();
        }

        sealed class CompositePass : ScriptableRenderPass
        {
            static readonly int OccludedColorId = Shader.PropertyToID("_RiverOccludedColor");
            readonly SurfacePass surface;
            readonly OccludedReceiversPass receivers;
            readonly WaterlinePass waterline;
            readonly OffscreenReceiversPass offscreen;
            public Material material;

            public CompositePass(SurfacePass surface, OccludedReceiversPass receivers, WaterlinePass waterline, OffscreenReceiversPass offscreen)
            {
                this.surface = surface;
                this.receivers = receivers;
                this.waterline = waterline;
                this.offscreen = offscreen;
                profilingSampler = new ProfilingSampler("River / reflection and transmission");
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData data)
            {
                var renderer = data.cameraData.renderer;
                ConfigureTarget(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
                ConfigureClear(ClearFlag.None, Color.clear);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData data)
            {
                var cmd = CommandBufferPool.Get();
                BindDepthInputs(cmd, surface, receivers);
                cmd.SetGlobalTexture(OccludedColorId, receivers.ReceiverColor.nameID);
                if (waterline.passIndex >= 0) cmd.SetGlobalTexture(WaterlineMaskId, waterline.Mask.nameID);
                offscreen.Bind(cmd);
                cmd.DrawProcedural(Matrix4x4.identity, material, material.FindPass("RiverComposite"), MeshTopology.Triangles, 3);
                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);
            }
        }
    }
}
