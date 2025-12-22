#[compute]
#version 450
#extension GL_ARB_shading_language_include : require
#include "voxeltools.glsl.inc"

layout(set = 0, binding = 2, std430) restrict buffer PaletteDataBuffer {
    vec4[] color;
} paletteBuffer;

layout(set = 0, binding = 3, rgba32f) restrict uniform image2D image;

layout(set = 0, binding = 4, std430) restrict buffer CameraDataBuffer {
    mat4 cameraInverseProjection;
    mat4 cameraToWorld;
} cameraData;

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

const vec3 DIR_TO_LIGHT = normalize(vec3(.75, 1.2, 1.));

vec3 getEnvColor(vec3 origin, vec3 viewDir) {
    return vec3(26) / 255;
    float a = dot(vec3(0, 1, 0), viewDir);
    if (origin.y <= 0) {
        return mix(vec3(0xDC, 0xF2, 0xFE), vec3(0x45, 0xCA, 0xFF), a) / 0xFF;
    }
    return (a >= 0 ? mix(vec3(0xDC, 0xF2, 0xFE), vec3(0x45, 0xCA, 0xFF), a) :
        vec3(0x3A, 0x44, 0x5D)) / 0xFF;  
}

vec3 getVoxelColor(ivec3 coord, bool readFromA) {
    if (coord == gridData.activeVoxCoord.xyz) {
        return vec3(1, 1, 1);
    }
    uint val = read3dImage(coord, readFromA);
    return paletteBuffer.color[val].xyz;
}

int vertexAO_int(bool side1, bool side2, bool corner) {
    if (side1 && side2) {
        return 0;
    }
    return 3 - (int(side1) + int(side2) + int(corner));
}

float getAO(ivec3 hit_voxel, vec3 hit_point, ivec3 n) {
    int axis = abs(n.y + n.z * 2);
    
    int s = sign(n[axis]);

    int u = (axis + 1) % 3;
    int v = (axis + 2) % 3;
    
    ivec3 faceBase = hit_voxel;
    faceBase[axis] += s > 0 ? 1 : -1;

    const ivec2 verts[4] = ivec2[4]( ivec2(0,0), ivec2(1,0), ivec2(0,1), ivec2(1,1) );

    float aoVerts[4];
    for (int i = 0; i < 4; i++) {
        ivec2 uv = verts[i] * 2 - 1;
        ivec3 cornerCoord = faceBase;
        cornerCoord[u] += uv.x;
        cornerCoord[v] += uv.y;
        
        ivec3 side1Coord = faceBase;
        side1Coord[u] += uv.x;

        ivec3 side2Coord = faceBase;
        side2Coord[v] += uv.y;

        bool cornerOccupied = isVoxelOccupied(cornerCoord, gridData.renderFromA); 
        bool side1Occupied = isVoxelOccupied(side1Coord, gridData.renderFromA);
        bool side2Occupied = isVoxelOccupied(side2Coord, gridData.renderFromA);
        int aoVert = vertexAO_int(side1Occupied, side2Occupied, cornerOccupied);
        aoVerts[i] = float(aoVert) / 3.0;
    }

    vec3 localPos = hit_point - vec3(hit_voxel);
    float su = clamp(localPos[u], 0.0, 1.0);
    float sv = clamp(localPos[v], 0.0, 1.0);

    float a00 = aoVerts[0];
    float a10 = aoVerts[1];
    float a01 = aoVerts[2];
    float a11 = aoVerts[3];

    float aoU0 = mix(a00, a10, su);
    float aoU1 = mix(a01, a11, su);
    float ao = mix(aoU0, aoU1, sv);

    const float ao_factor = .2;
    ao = clamp(ao, 0.2, 1.0);
    return 1 + ao_factor * (ao - 1);
}

vec3 getShading(ivec3 normal) {
    if (normal == ivec3(0, 1, 0)) return vec3(1.0, 1.0, 1.0);
    if (normal == ivec3(1, 0, 0)) return vec3(0.9372549019607843, 0.9254901960784314, 1.0);
    if (normal == ivec3(0, 0, -1)) return vec3(0.8352941176470589, 0.8274509803921568, 0.9058823529411765);
    if (normal == ivec3(-1, 0, 0)) return vec3(0.788235294117647, 0.7764705882352941, 0.8549019607843137);
    if (normal == ivec3(0, 0, 1)) return vec3(0.7058823529411765, 0.6980392156862745, 0.7764705882352941);
    if (normal == ivec3(0, -1, 0)) return vec3(0.8666666666666667, 0.8549019607843137, 0.9372549019607843);
}

float minDistanceBetweenSegmentAndRay(vec3 segP, vec3 segD, vec3 rayO, vec3 rayD, out vec3 segmentToRay) {
    vec3 d1 = segD;
    vec3 d2 = normalize(rayD);
    vec3 r  = segP - rayO;

    float a = dot(d1,d1), b = dot(d1,d2), c = dot(d2,d2);
    float e = dot(r,d1), f = dot(r,d2);
    float det = a*c - b*b;

    float t = 0.0, s = 0.0;
    if (det != 0.0) {
        t = (b*f - c*e) / det;
        s = (a*f - b*e) / det;
    }
    t = clamp(t, 0.0, 1.0);
    s = max(s, 0.0);
    if (s == 0.0) t = clamp(dot(rayO - segP, d1) / a, 0.0, 1.0);

    float distSign = isPointInBox(rayO + s*d2, vec3(0), gridData.voxelResolution.xyz) ? -1 : 1;
    segmentToRay = (rayO + s*d2) - (segP + t*d1);
    return length(segmentToRay) * distSign;
}

bool isRayCloseToVoxelGridEdge(vec3 rayO, vec3 rayD) {
    vec3 R = vec3(gridData.voxelResolution);
    const int EDGE_COUNT = 12;
    const vec3 edgeNormals[EDGE_COUNT * 2] = vec3[](
        vec3(0, -1, 0), vec3(0, 0, -1), vec3(0, 1, 0), vec3(0, 0, -1),
        vec3(0, -1, 0), vec3(0, 0, 1), vec3(0, 1, 0), vec3(0, 0, 1),

        vec3(-1, 0, 0), vec3(0, 0, -1), vec3(1, 0, 0), vec3(0, 0, -1),
        vec3(-1, 0, 0), vec3(0, 0, 1), vec3(1, 0, 0), vec3(0, 0, 1),

        vec3(0, -1, 0), vec3(-1, 0, 0), vec3(0, -1, 0), vec3(1, 0, 0),
        vec3(0, 1, 0), vec3(-1, 0, 0), vec3(0, 1, 0), vec3(1, 0, 0)
    );
    const vec3 starts[EDGE_COUNT] = vec3[](
        vec3(0, 0, 0), vec3(0, R.y, 0), vec3(0, 0, R.z), vec3(0, R.y, R.z),
        vec3(0, 0, 0), vec3(R.x, 0, 0), vec3(0, 0, R.z), vec3(R.x, 0, R.z),
        vec3(0, 0, 0), vec3(R.x, 0, 0), vec3(0, R.y, 0), vec3(R.x, R.y, 0)
    );
    const vec3 dirs[EDGE_COUNT] = vec3[](
        vec3(R.x, 0, 0), vec3(R.x, 0, 0), vec3(R.x, 0, 0), vec3(R.x, 0, 0),
        vec3(0, R.y, 0), vec3(0, R.y, 0), vec3(0, R.y, 0), vec3(0, R.y, 0),
        vec3(0, 0, R.z), vec3(0, 0, R.z), vec3(0, 0, R.z), vec3(0, 0, R.z)
    );

    for (int i = 0; i < EDGE_COUNT; i++) {
        if ((dot(rayD, edgeNormals[i * 2]) < 0) && (dot(rayD, edgeNormals[i * 2 + 1]) < 0)) {
            continue;
        }
        vec3 segmentToRay;
        float dist = minDistanceBetweenSegmentAndRay(starts[i], dirs[i], rayO, rayD, segmentToRay);
        if ((dot(segmentToRay, edgeNormals[i * 2]) < 0) && (dot(segmentToRay, edgeNormals[i * 2 + 1]) < 0)) {
            continue;
        }
        if (dist >= 0 && dist <= 0.1) return true;
    }
    return false;
}

void main() {
    ivec2 size = imageSize(image);
    ivec2 pixelCoord = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixelCoord, size)))
    return;
    vec2 uv = 1. * pixelCoord / size * 2 - 1;
    uv.y = -uv.y;
    
    vec3 origin = cameraData.cameraToWorld[3].xyz;
    vec4 d4 = (cameraData.cameraInverseProjection * vec4(uv, 0, 1));
    vec3 dir = d4.xyz;
    dir = mat3(cameraData.cameraToWorld) * normalize(dir);

    vec3 color;
    vec3 hit_point;
    ivec3 hit_vox_coord;
    ivec3 hit_normal;
    bool is_hit = traversal(origin, dir, hit_vox_coord, hit_point, hit_normal);
    bool shadow = shadowPass(hit_point + DIR_TO_LIGHT * FLT_EPS, DIR_TO_LIGHT);

    if (is_hit) {
        color = getVoxelColor(hit_vox_coord, gridData.renderFromA);
        color *= getShading(hit_normal);
        color *= getAO(hit_vox_coord, hit_point, hit_normal);
    } else {
        if (isRayCloseToVoxelGridEdge(origin, dir)) {
            color = vec3(1, 1, 1);
        } else {
            color = getEnvColor(origin, dir);
            if (!rayGround(origin, dir, hit_point)) {
                shadow = false;
            }
        }
    }
    imageStore(image, pixelCoord, vec4(color, 1));
}
