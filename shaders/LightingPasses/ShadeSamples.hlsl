/***************************************************************************
 # Copyright (c) 2020-2022, NVIDIA CORPORATION.  All rights reserved.
 #
 # NVIDIA CORPORATION and its licensors retain all intellectual property
 # and proprietary rights in and to this software, related documentation
 # and any modifications thereto.  Any use, reproduction, disclosure or
 # distribution of this software and related documentation without an express
 # license agreement from NVIDIA CORPORATION is strictly prohibited.
 **************************************************************************/

#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/ResamplingFunctions.hlsli>

#ifdef WITH_NRD
#define NRD_HEADER_ONLY
#include <NRD.hlsli>
#endif

#include "ShadingHelpers.hlsli"

#if USE_RAY_QUERY
[numthreads(RTXDI_SCREEN_SPACE_GROUP_SIZE, RTXDI_SCREEN_SPACE_GROUP_SIZE, 1)]
void main(uint2 GlobalIndex : SV_DispatchThreadID, uint2 LocalIndex : SV_GroupThreadID, uint2 GroupIdx : SV_GroupID)
#else
[shader("raygeneration")]
void RayGen()
#endif
{
#if !USE_RAY_QUERY
    uint2 GlobalIndex = DispatchRaysIndex().xy;
#endif

    const RTXDI_ResamplingRuntimeParameters params = g_Const.runtimeParams;

    uint2 pixelPosition = RTXDI_ReservoirPosToPixelPos(GlobalIndex, g_Const.runtimeParams);

    RAB_Surface surface = RAB_GetGBufferSurface(pixelPosition, false);

    RTXDI_Reservoir reservoir = RTXDI_LoadReservoir(params, GlobalIndex, g_Const.shadeInputBufferIndex);

    float3 diffuse = 0;
    float3 specular = 0;
    float lightDistance = 0;
    float2 currLuminance = 0;

    if (RTXDI_IsValidReservoir(reservoir))
    {
        RAB_LightInfo lightInfo = RAB_LoadLightInfo(RTXDI_GetReservoirLightIndex(reservoir), false);

        RAB_LightSample lightSample = RAB_SamplePolymorphicLight(lightInfo,
            surface, RTXDI_GetReservoirSampleUV(reservoir));

        bool needToStore = ShadeSurfaceWithLightSample(reservoir, surface, lightSample,
            /* previousFrameTLAS = */ false, /* enableVisibilityReuse = */ true, diffuse, specular, lightDistance);
    
        currLuminance = float2(calcLuminance(diffuse * surface.diffuseAlbedo), calcLuminance(specular));
    
        specular = DemodulateSpecular(surface.specularF0, specular);

        if (needToStore)
        {
            RTXDI_StoreReservoir(reservoir, params, GlobalIndex, g_Const.shadeInputBufferIndex);
        }
    }

    // Store the sampled lighting luminance for the gradient pass.
    // Discard the pixels where the visibility was reused, as gradients need actual visibility.
    u_RestirLuminance[GlobalIndex] = currLuminance * (reservoir.age > 0 ? 0 : 1);
    
#if RTXDI_REGIR_MODE != RTXDI_REGIR_DISABLED
    if (g_Const.visualizeRegirCells)
    {
        diffuse *= RTXDI_VisualizeReGIRCells(g_Const.runtimeParams, RAB_GetSurfaceWorldPos(surface));
    }
#endif

    StoreShadingOutput(GlobalIndex, pixelPosition, 
        surface.viewDepth, surface.roughness, diffuse, specular, lightDistance, true, g_Const.enableDenoiserInputPacking);
}
