//-----------------------------------------------------
// � Copyright 2024 Case Engine. All Rights Reserved. 
//-----------------------------------------------------

#include "..\\Common.hlsli"
//#include "../Globals/GlobalsPS.hlsli"

struct VSToPS
{
    float4 Pos : SV_POSITION;
    float2 Tex  : TEX;
};


// Cloud types height density gradients
#define STRATUS_GRADIENT        float4(0.0f, 0.1f, 0.2f, 0.3f)
#define STRATOCUMULUS_GRADIENT  float4(0.02f, 0.2f, 0.48f, 0.625f)
#define CUMULUS_GRADIENT        float4(0.0f, 0.1625f, 0.88f, 0.98f)
#define CONE_STEP 0.1666666


static const float PLANET_RADIUS = 600000.0f;
static float3 PLANET_CENTER = float3(0.0f, -PLANET_RADIUS, 0.0f);

Texture2D WeatherTx    : register(t0);
Texture3D CloudTx      : register(t1);
Texture3D WorleyTx     : register(t2);
Texture2D DepthTx      : register(t3);




static const float BAYER_FACTOR = 1.0f / 16.0f;
static const float BAYER_FILTER[16] =
{
    0.0f * BAYER_FACTOR, 8.0f * BAYER_FACTOR, 2.0f * BAYER_FACTOR, 10.0f * BAYER_FACTOR,
	12.0f * BAYER_FACTOR, 4.0f * BAYER_FACTOR, 14.0f * BAYER_FACTOR, 6.0f * BAYER_FACTOR,
	3.0f * BAYER_FACTOR, 11.0f * BAYER_FACTOR, 1.0f * BAYER_FACTOR, 9.0f * BAYER_FACTOR,
	15.0f * BAYER_FACTOR, 7.0f * BAYER_FACTOR, 13.0f * BAYER_FACTOR, 5.0f * BAYER_FACTOR
};

// Cone sampling random offsets (for light)
static float3 NOISE_KERNEL_CONE_SAMPLING[6] =
{
    float3(0.38051305, 0.92453449, -0.02111345),
	float3(-0.50625799, -0.03590792, -0.86163418),
	float3(-0.32509218, -0.94557439, 0.01428793),
	float3(0.09026238, -0.27376545, 0.95755165),
	float3(0.28128598, 0.42443639, -0.86065785),
	float3(-0.16852403, 0.14748697, 0.97460106)
};

float3 ToClipSpaceCoord(float2 tex)
{
    float2 ray;
    ray.x = 2.0 * tex.x - 1.0;
    ray.y = 1.0 - tex.y * 2.0;
    return float3(ray, 1.0);
}

float BeerLaw(float d)
{
    return exp(-d);
}

float SugarPowder(float d)
{
    return (1.0f - exp(-2.0f * d));
}

float HenyeyGreenstein(float cosAngle, float g)
{
    float gg = g * g;
    return (1.0f - gg) / pow(1.0f + gg - 2.0f * g * cosAngle, 1.5f);
}

float GetHeightFraction(float3 position)
{
    float innerRadius = PLANET_RADIUS + weatherData.cloudsBottomHeight; 
    float outerRadius = innerRadius + weatherData.cloudsTopHeight; 
    return (length(position - PLANET_CENTER) - innerRadius) / (outerRadius - innerRadius);
}

float Remap(float originalValue, float originalMin, float originalMax, float newMin, float newMax)
{
    return newMin + (((originalValue - originalMin) / (originalMax - originalMin)) * (newMax - newMin));
}

float2 GetUVProjection(float3 p)
{
    float innerRadius = PLANET_RADIUS + weatherData.cloudsBottomHeight;
    return p.xz / innerRadius + 0.5f;
}

float GetDensityForCloud(float heightFraction, float cloudType)
{
    float stratusFactor = 1.0 - clamp(cloudType * 2.0, 0.0, 1.0);
    float stratoCumulusFactor = 1.0 - abs(cloudType - 0.5) * 2.0;
    float cumulusFactor = clamp(cloudType - 0.5, 0.0, 1.0) * 2.0;

    float4 baseGradient = stratusFactor * STRATUS_GRADIENT + stratoCumulusFactor * STRATOCUMULUS_GRADIENT + cumulusFactor * CUMULUS_GRADIENT;
    return smoothstep(baseGradient.x, baseGradient.y, heightFraction) - smoothstep(baseGradient.z, baseGradient.w, heightFraction);
}

float SampleCloudDensity(float3 p, bool useHighFreq, float lod)
{
    float heightFraction = GetHeightFraction(p);
    float3 scroll = weatherData.windDir * (heightFraction * 750.0f + weatherData.time * weatherData.windSpeed);
    
    float2 UV = GetUVProjection(p);
    float2 dynamicUV = GetUVProjection(p + scroll);

    if (heightFraction <= 0.0f || heightFraction >= 1.0f)
        return 0.0f;

    // low frequency sample
    float4 lowFreqNoise = CloudTx.SampleLevel(LinearWrapSampler, float3(UV * weatherData.crispiness, heightFraction), lod);
    float lowFreqFBM = dot(lowFreqNoise.gba, float3(0.625, 0.25, 0.125));
    float cloudSample = Remap(lowFreqNoise.r, -(1.0f - lowFreqFBM), 1.0f, 0.0f, 1.0f);
	 
    float density = GetDensityForCloud(heightFraction, weatherData.cloudType);
    cloudSample *= density / max(heightFraction, 0.001f);

    float3 weatherNoise = WeatherTx.Sample(LinearWrapSampler, dynamicUV).rgb;
    float cloudWeatherCoverage = weatherNoise.r * weatherData.coverage;
    float cloudSampleWithCoverage = Remap(cloudSample, cloudWeatherCoverage, 1.0f, 0.0f, 1.0f);
    cloudSampleWithCoverage *= cloudWeatherCoverage;

    // high frequency sample
    if (useHighFreq)
    {
        float3 highFreqNoise = WorleyTx.SampleLevel(LinearWrapSampler, float3(dynamicUV * weatherData.crispiness, heightFraction) * weatherData.curliness, lod).rgb;
        float highFreqFBM = dot(highFreqNoise.rgb, float3(0.625, 0.25, 0.125));
        float highFreqNoiseModifier = lerp(highFreqFBM, 1.0f - highFreqFBM, clamp(heightFraction * 10.0f, 0.0f, 1.0f));
        cloudSampleWithCoverage = cloudSampleWithCoverage - highFreqNoiseModifier * (1.0 - cloudSampleWithCoverage);
        cloudSampleWithCoverage = Remap(cloudSampleWithCoverage * 2.0, highFreqNoiseModifier * 0.2, 1.0f, 0.0f, 1.0f);
    }

    return clamp(cloudSampleWithCoverage, 0.0f, 1.0f);
}


float LightEnergy(float d, float cosAngle)
{
    return 5.0 * BeerLaw(d) * SugarPowder(d) * HenyeyGreenstein(cosAngle, 0.2f);
}


float RaymarchToLight(float3 origin, float stepSize, float3 lightDir, float originalDensity, float lightDotEye)
{
    float3 startPos = origin;
    
    float deltaStep = stepSize * 6.0f;
    float3 rayStep = lightDir * deltaStep;
    const float coneStep = 1.0f / 6.0f;
    float coneRadius = 1.0f;
    float coneDensity = 0.0;
    
    float density = 0.0;
    const float densityThreshold = 0.3f;
    
    float invDepth = 1.0 / deltaStep;
    float sigmaDeltaStep = -deltaStep * weatherData.absorption;
    float3 pos;

    float finalTransmittance = 1.0;

    [unroll(6)]
    for (int i = 0; i < 6; i++)
    {
        pos = startPos + coneRadius * NOISE_KERNEL_CONE_SAMPLING[i] * float(i);

        float heightFraction = GetHeightFraction(pos);
        if (heightFraction >= 0)
        {
            float cloudDensity = SampleCloudDensity(pos, density < densityThreshold, i / 16.0f);
            
            if (cloudDensity > 0.0)
            {
                density += cloudDensity;
                float transmittance = exp(sigmaDeltaStep * density);
                coneDensity += (cloudDensity * transmittance);
            }

        }
        startPos += rayStep;
        coneRadius += coneStep;
    }
    return LightEnergy(coneDensity, lightDotEye);
}


float4 RaymarchToCloud(float2 texCoord, float3 startPos, float3 endPos, float3 skyColor, out float4 cloudPos)
{
    const float minTransmittance = 0.1f;
    const int steps = 32;
    float4 finalColor = float4(0.0, 0.0, 0.0, 0.0);
    
    float3 path = endPos - startPos;
    float len = length(path);
	
    float deltaStep = len / (float) steps;
    float3 dir = path / len;
    dir *= deltaStep;
    
    uint height, width, levels;
    
    DepthTx.GetDimensions(0, width, height, levels);
    
    float2 fragCoord = texCoord * float2(width, height);
    int a = int(fragCoord.x) % 4;
    int b = int(fragCoord.y) % 4;
    startPos += dir * BAYER_FILTER[a * 4 + b];

    float3 pos = startPos;
    float density = 0.0f;
    float LdotV = dot(normalize(weatherData.lightDir.rgb), normalize(dir));

    float finalTransmittance = 1.0f;
    float sigmaDeltaStep = -deltaStep * weatherData.densityFactor;
    bool entered = false;

    [unroll(steps)]
    for (int i = 0; i < steps; ++i)
    {
        float densitySample = SampleCloudDensity(pos, true, i / 16.0f);
        if (densitySample > 0.0f)
        {
            if (!entered)
            {
                cloudPos = float4(pos, 1.0);
                entered = true;
            }

            density += densitySample;
            float lightEnergy = RaymarchToLight(pos, deltaStep * 0.1f, weatherData.lightDir.rgb, densitySample, LdotV);

            float height = GetHeightFraction(pos);
            float4 src = float4(weatherData.lightColor.rgb * lightEnergy + weatherData.ambientColor.rgb, densitySample);
            src.rgb *= src.a;
            finalColor = (1.0 - finalColor.a) * src + finalColor;

            if (finalColor.a >= 0.95)
                break;
        }

        if (finalTransmittance <= minTransmittance) break;
        pos += dir;
    }
    return finalColor;
}


bool IntersectSphere(float3 o, float3 d, out float3 minT, out float3 maxT)
{
    float innerRadius = PLANET_RADIUS + weatherData.cloudsBottomHeight;
    float outerRadius = innerRadius + weatherData.cloudsTopHeight;
	
    float3 sphereToOrigin = (o - PLANET_CENTER);
    float b = dot(d, sphereToOrigin);
    float c = dot(sphereToOrigin, sphereToOrigin);
    float sqrtOpInner = b * b - (c - innerRadius * innerRadius);

	float maxSInner;
    if (sqrtOpInner < 0.0)  return false;
	
    float deInner = sqrt(sqrtOpInner);
    float solAInner = -b - deInner;
    float solBInner = -b + deInner;

    maxSInner = max(solAInner, solBInner);

    if (maxSInner < 0.0) return false;

    maxSInner = maxSInner < 0.0 ? 0.0 : maxSInner;
    float sqrtOpOuter = b * b - (c - outerRadius * outerRadius);

    if (sqrtOpOuter < 0.0) return false;

    float deOuter = sqrt(sqrtOpOuter);
    float solAOuter = -b - deOuter;
    float solBOuter = -b + deOuter;

    float maxSOuter = max(solAOuter, solBOuter);

    if (maxSOuter < 0.0) return false;

    maxSOuter = maxSOuter < 0.0 ? 0.0 : maxSOuter;

    float minSol = min(maxSInner, maxSOuter);
    if (minSol > PLANET_RADIUS * 0.3f)  return false;

    float maxSol = max(maxSInner, maxSOuter);

    minT = o + d * minSol;
    maxT = o + d * maxSol;
    return true;
}


struct PSOutput
{
    float4 color : SV_TARGET;
    float  depth : SV_Depth;
};


PSOutput VolumetricClouds(VSToPS pin) 
{
    float depth = DepthTx.SampleLevel(PointWrapSampler, pin.Tex, 0.0f).r;
    
    PSOutput output = (PSOutput)0;
    output.color = 0.0f;
    output.depth = depth;

    if (depth < 0.99999f) return output;

    float4 rayClipSpace = float4(ToClipSpaceCoord(pin.Tex), 1.0);
    float4 rayView = mul(rayClipSpace, frameData.inverseProjection);
    rayView = float4(rayView.xy, 1.0, 0.0);
    float3 worldDir = mul(rayView, frameData.inverseView).xyz;
    worldDir = normalize(worldDir);
    
    float3 startPos, endPos;
    bool intersect = IntersectSphere(frameData.cameraPosition.xyz, worldDir, startPos, endPos);
    if (intersect)
    {
        float4 cloudsColor = 0.0f;
        float4 cloudDistance = 0.0f;
        cloudsColor = RaymarchToCloud(pin.Tex, startPos, endPos, float3(0,0,0), cloudDistance);

        output.color = cloudsColor;
        output.depth = 0.9999f;
    }
    return output;
}



