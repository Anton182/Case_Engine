//-----------------------------------------------------
// � Copyright 2024 Case Engine. All Rights Reserved. 
//-----------------------------------------------------

#pragma once


// Namespace Case_Engine
namespace Case_Engine
{
	struct SimpleVertex
	{
		Vector3 position;
	};

	struct TexturedVertex
	{
		Vector3 position;
		Vector2 uv;
	};

	struct TexturedNormalVertex
	{
		Vector3 position;
		Vector2 uv;
		Vector3 normal;
	};

	struct ColoredVertex
	{
		Vector3 position;
		Vector4 color;
	};

	struct ColoredNormalVertex
	{
		Vector3 position;
		Vector4 color;
		Vector3 normal;
	};

	struct NormalVertex
	{
		Vector3 position;
		Vector3 normal;
	};

	struct CompleteVertex
	{
		Vector3 position;
		Vector2 uv;
		Vector3 normal;
		Vector3 tangent;
		Vector3 bitangent;
	};

}

