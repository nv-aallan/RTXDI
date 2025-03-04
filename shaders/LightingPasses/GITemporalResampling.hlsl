/***************************************************************************
 # Copyright (c) 2023, NVIDIA CORPORATION.  All rights reserved.
 #
 # NVIDIA CORPORATION and its licensors retain all intellectual property
 # and proprietary rights in and to this software, related documentation
 # and any modifications thereto.  Any use, reproduction, disclosure or
 # distribution of this software and related documentation without an express
 # license agreement from NVIDIA CORPORATION is strictly prohibited.
 **************************************************************************/

#pragma pack_matrix(row_major)

#if USE_RAY_QUERY
#define RTXDI_ENABLE_BOILING_FILTER
#define RTXDI_BOILING_FILTER_GROUP_SIZE RTXDI_SCREEN_SPACE_GROUP_SIZE
#endif

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/GIResamplingFunctions.hlsli>

#if USE_RAY_QUERY
[numthreads(RTXDI_SCREEN_SPACE_GROUP_SIZE, RTXDI_SCREEN_SPACE_GROUP_SIZE, 1)]
void main(uint2 GlobalIndex : SV_DispatchThreadID, uint2 LocalIndex : SV_GroupThreadID)
#else
[shader("raygeneration")]
void RayGen()
#endif
{
#if !USE_RAY_QUERY
    uint2 GlobalIndex = DispatchRaysIndex().xy;
#endif
    uint2 pixelPosition = RTXDI_ReservoirPosToPixelPos(GlobalIndex, g_Const.runtimeParams);

    RAB_RandomSamplerState rng = RAB_InitRandomSampler(GlobalIndex, 7);
    
    const RAB_Surface primarySurface = RAB_GetGBufferSurface(pixelPosition, false);
    
    const uint2 reservoirPosition = RTXDI_PixelPosToReservoirPos(pixelPosition, g_Const.runtimeParams);
    RTXDI_GIReservoir reservoir = RTXDI_LoadGIReservoir(g_Const.runtimeParams, reservoirPosition, g_Const.initialOutputBufferIndex);

    float3 motionVector = t_MotionVectors[pixelPosition].xyz;
    motionVector = convertMotionVectorToPixelSpace(g_Const.view, g_Const.prevView, pixelPosition, motionVector);

    if (RAB_IsSurfaceValid(primarySurface)) {
        RTXDI_GITemporalResamplingParameters tParams;

        tParams.screenSpaceMotion = motionVector;
        tParams.sourceBufferIndex = g_Const.temporalInputBufferIndex;
        tParams.maxHistoryLength = g_Const.maxHistoryLength;
        tParams.biasCorrectionMode = g_Const.temporalBiasCorrection;
        tParams.depthThreshold = g_Const.temporalDepthThreshold;
        tParams.normalThreshold = g_Const.temporalNormalThreshold;
        tParams.enablePermutationSampling = g_Const.enablePermutationSampling;
        tParams.enableFallbackSampling = g_Const.enableFallbackSampling;

        // Age threshold should vary.
        // This is to avoid to die a bunch of GI reservoirs at once at a disoccluded area.
        tParams.maxReservoirAge = g_Const.giReservoirMaxAge * (0.5 + RAB_GetNextRandom(rng) * 0.5);

        // Execute resampling.
        reservoir = RTXDI_GITemporalResampling(pixelPosition, primarySurface, reservoir, rng, tParams, g_Const.runtimeParams);
    }

#ifdef RTXDI_ENABLE_BOILING_FILTER
    if (g_Const.boilingFilterStrength > 0)
    {
        RTXDI_GIBoilingFilter(LocalIndex, g_Const.boilingFilterStrength, g_Const.runtimeParams, reservoir);
    }
#endif

    RTXDI_StoreGIReservoir(reservoir, g_Const.runtimeParams, reservoirPosition, g_Const.temporalOutputBufferIndex);
}
