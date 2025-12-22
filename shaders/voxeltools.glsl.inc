layout(set = 0, binding = 0, r8ui) uniform uimage3D image3dA;
layout(set = 0, binding = 1, r8ui) uniform uimage3D image3dB;

layout(push_constant, std430) restrict uniform GridData {
    ivec4 activeVoxCoord;
    ivec4 activeVoxNormal;
    ivec4 secondaryVoxCoord;
    ivec4 secondaryVoxNormal;
    ivec4 voxelResolution;
    bool renderFromA;
    int dummy1;
    int dummy2;
    int dummy3;
} gridData;

const float FLT_MAX = 3.4028235e+38;
const float FLT_EPS = 0.0001;

uint read3dImage(ivec3 coord, bool readFromA) {
    return readFromA ? imageLoad(image3dA, coord).x : imageLoad(image3dB, coord).x;
}

void write3dImage(ivec3 coord, bool writeToA, uint val) {
    writeToA ? imageStore(image3dA, coord, uvec4(val, 0, 0, 0)) : imageStore(image3dB, coord, uvec4(val, 0, 0, 0));
}

bool isPointInBox(vec3 coord, vec3 a, vec3 b) {
    return all(greaterThanEqual(coord, min(a, b))) &&
        all(lessThanEqual(coord, max(a, b)));
}

bool isVoxelOccupied(ivec3 coord, bool readFromA) {
    if (!isPointInBox(coord, ivec3(0), gridData.voxelResolution.xyz)) {
        return false;
    }

    uint val = read3dImage(coord, readFromA);
    return val != 0u;
}

ivec3 getNormal(int axis, ivec3 istep) {
    return ivec3[3](
        ivec3(-istep.x, 0, 0),
        ivec3(0, -istep.y, 0),
        ivec3(0, 0, -istep.z)
    )[axis];
}

bool rayAABB(vec3 origin, vec3 dir, vec3 inv_dir, out ivec3 coord) {
    if (0 <= origin.x && origin.x <= gridData.voxelResolution.x + 1 &&
        0 <= origin.y && origin.y <= gridData.voxelResolution.y + 1 &&
        0 <= origin.z && origin.z <= gridData.voxelResolution.z + 1) {
        coord = ivec3(floor(origin));
        return true;
    }

    vec3 t0 =  -origin * inv_dir;
    vec3 t1 = (gridData.voxelResolution.xyz - origin) * inv_dir;

    vec3 tmin = min(t0, t1);
    vec3 tmax = max(t0, t1);

    float tNear = max(max(tmin.x, tmin.y), tmin.z);
    float tFar = min(min(tmax.x, tmax.y), tmax.z);

    if (tFar >= tNear && tNear >= 0) {
        coord = ivec3(floor(origin + dir * (tNear - FLT_EPS)));
        return true;
    }
    return false;
}

bool rayGround(vec3 origin, vec3 dir, out vec3 point) {
    if (dir.y >= 0 || origin.y <= 0) {
        return false;
    }

    point = origin - origin.y / dir.y * dir;
    return true;
}

bool traversal(vec3 origin, vec3 dir, out ivec3 hitCoord, out vec3 hit_point, out ivec3 normal, bool shadowpass) {
    vec3 inv_dir = 1. / dir;
    vec3 sgn_dir = sign(inv_dir);
    inv_dir = clamp(inv_dir, vec3(-FLT_MAX), vec3(FLT_MAX));

    if (!rayAABB(origin, dir, inv_dir, hitCoord)) {
        rayGround(origin, dir, hit_point);
        return false;
    }

    if (isVoxelOccupied(hitCoord, gridData.renderFromA)) {
        return true;
    }

    vec3 t = (hitCoord - origin + 0.5 * (1 + sgn_dir)) * inv_dir;
    float t_hit = 0;
    ivec3 istep = ivec3(sgn_dir);
    vec3 delta = inv_dir * sgn_dir;
    
    int axis = 0;
    int steps = 0;
    while (true) {
        steps++;
        if (t.x < t.y) {
            if (t.x < t.z) {
                hitCoord.x += istep.x;
                if (hitCoord.x < 0 || hitCoord.x >= gridData.voxelResolution.x) break;
                t_hit = t.x;
                t.x += delta.x;
                axis = 0;
            } else {
                hitCoord.z += istep.z;
                if (hitCoord.z < 0 || hitCoord.z >= gridData.voxelResolution.z) break;
                t_hit = t.z;
                t.z += delta.z;
                axis = 2;
            }
        } else {
            if (t.y < t.z) {
                hitCoord.y += istep.y;
                if (hitCoord.y < 0 || hitCoord.y >= gridData.voxelResolution.y) break;
                t_hit = t.y;
                t.y += delta.y;
                axis = 1;
            } else {
                hitCoord.z += istep.z;
                if (hitCoord.z < 0 || hitCoord.z >= gridData.voxelResolution.z) break;
                t_hit = t.z;
                t.z += delta.z;
                axis = 2;
            }
        }
        hit_point = origin + dir * t_hit;
        normal = getNormal(axis, istep);
        if (isVoxelOccupied(hitCoord, gridData.renderFromA)){
            return true;
        }
    }
    
    if (hitCoord == gridData.activeVoxCoord.xyz) {
        return true;
    }

    if (shadowpass) {
        return false;
    }

    rayGround(origin, dir, hit_point);
    return false;
}

bool traversal(vec3 origin, vec3 dir, out ivec3 hitCoord, out vec3 hit_point, out ivec3 normal) {
    return traversal(origin, dir, hitCoord, hit_point, normal, false);
}

bool shadowPass(vec3 origin, vec3 dir) {
    vec3 tmp1;
    return traversal(origin, dir, tmp1, tmp1, tmp1, true);
}