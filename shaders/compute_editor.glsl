#[compute]
#version 450
#extension GL_ARB_shading_language_include : require
#include "voxeltools.glsl.inc"

layout(set = 0, binding = 2, std430) buffer EditingDataBuffer {
    int tool;
    int selectionType;
    int colorIndex;
    uint stateFlags;
    int brushSize;
} editingData;

layout(set = 0, binding = 3, r32ui) uniform coherent uimage3D voxMask;

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

const ivec2 faceOffsets4[] = {
    ivec2(-1, 0),
    ivec2(1, 0),
    ivec2(0, -1),
    ivec2(0, 1)
};

const int TOOL_ADD = 1;
const int TOOL_DELETE = 2;
const int TOOL_PAINT = 3;

const int SELECTION_TYPE_BOX = 1;
const int SELECTION_TYPE_FACE = 2;
const int SELECTION_TYPE_BRUSH = 3;

const uint MASK_BIT = 1;
const uint MARK_FOR_EDITING_BIT = 2;
const uint VISITED_BIT = 4;

const uint STATE_FLAG_MASK_CHANGED = 1;
const uint STATE_FLAG_RECALCULATE_VOX_MASK = 2;

bool hasFlag(uint flags, uint bit) {
    return (flags & bit) == bit;
}

void setMask(ivec3 coord) {
    if (!isPointInBox(coord, ivec3(0), gridData.voxelResolution.xyz)) {
        return;
    }
    if (!hasFlag(imageAtomicOr(voxMask, coord, MASK_BIT), MASK_BIT)) {
        editingData.stateFlags |= STATE_FLAG_MASK_CHANGED;
    }
}

void markForEditing(ivec3 coord) {
    if (!isPointInBox(coord, ivec3(0), gridData.voxelResolution.xyz)) {
        return;
    }
    imageAtomicOr(voxMask, coord, MARK_FOR_EDITING_BIT);
}

void unmarkForEditing(ivec3 coord) {
    if (!isPointInBox(coord, ivec3(0), gridData.voxelResolution.xyz)) {
        return;
    }
    imageAtomicAnd(voxMask, coord, ~MARK_FOR_EDITING_BIT);
}

bool canSetFaceMask(ivec3 coord) {
    if (!isPointInBox(coord, ivec3(0), gridData.voxelResolution.xyz - 1)) {
        return false;
    }
    if (read3dImage(coord, !gridData.renderFromA) == 0) {
        return false;
    }
    if (read3dImage(coord + gridData.activeVoxNormal.xyz, !gridData.renderFromA) != 0) {
        return false;
    }
    return true;
}

void createFaceMask(ivec3 coord) {
    if (hasFlag(imageLoad(voxMask, coord).x, VISITED_BIT)) {
        return;
    }
    int normalAxis = abs(gridData.activeVoxNormal.y + 2 * gridData.activeVoxNormal.z);    
    if (coord[normalAxis] != gridData.activeVoxCoord[normalAxis]) {
        imageAtomicOr(voxMask, coord, VISITED_BIT);
        return;
    }
    if (!canSetFaceMask(coord)) {
        imageAtomicOr(voxMask, coord, VISITED_BIT);
        return;
    }
    if (coord == gridData.activeVoxCoord.xyz) {
        setMask(coord);
    } else if (!hasFlag(imageLoad(voxMask, coord).x, MASK_BIT)) {
        return;
    }
    for(int i = 0; i < 4; i++) {
        ivec3 adjacentCoord = coord;
        int offsetComponent = 0;
        for(int j = 0; j < 3; j++) {
            if (j == normalAxis) {
                continue;
            }
            adjacentCoord[j] += faceOffsets4[i][offsetComponent];
            offsetComponent++;
        }
        if (canSetFaceMask(adjacentCoord)) {
            setMask(adjacentCoord);
        }
    }
    imageAtomicOr(voxMask, coord, VISITED_BIT);
}

void createBoxMask(ivec3 coord) {
    
}

void createBrushMask(ivec3 coord) {

}

void createFaceEditingMarks(ivec3 coord) {
    unmarkForEditing(coord);
    ivec3 first = gridData.activeVoxCoord.xyz;
    if (editingData.tool == TOOL_ADD) {
        first += gridData.activeVoxNormal.xyz;
    }
    ivec3 second = gridData.secondaryVoxCoord.xyz;
    int normalAxis = abs(gridData.activeVoxNormal.y + 2 * gridData.activeVoxNormal.z);
    if (!((first[normalAxis] <= coord[normalAxis] && coord[normalAxis] <= second[normalAxis]) ||
        (second[normalAxis] <= coord[normalAxis] && coord[normalAxis] <= first[normalAxis]))) {
            return;
        }
    ivec3 offsettedCoord = coord;
    offsettedCoord[normalAxis] = gridData.activeVoxCoord[normalAxis];
    if (hasFlag(imageLoad(voxMask, offsettedCoord).x, MASK_BIT)) {
        markForEditing(coord);
    }
}

void createBoxEditingMarks(ivec3 coord) {
    unmarkForEditing(coord);
    ivec3 first = gridData.activeVoxCoord.xyz;
    first += editingData.tool == TOOL_ADD ? gridData.activeVoxNormal.xyz : ivec3(0);
    ivec3 second = gridData.secondaryVoxCoord.xyz;
    second += editingData.tool == TOOL_ADD ? gridData.secondaryVoxNormal.xyz : ivec3(0);
    if (isPointInBox(coord, first, second)) {
        markForEditing(coord);
    }
}

void createBrushEditingMarks(ivec3 coord) {
    float dist = length(coord - gridData.secondaryVoxCoord.xyz);
    if (dist < editingData.brushSize) {
        markForEditing(coord);
    }
}

void main() {
    ivec3 voxCoord = ivec3(gl_GlobalInvocationID.xyz);
    
    if (!isPointInBox(voxCoord, ivec3(0), gridData.voxelResolution.xyz)) {
        return;
    }
    if (gridData.activeVoxCoord.xyz != ivec3(-1) && gridData.secondaryVoxCoord.xyz != ivec3(-1)) {
        if (hasFlag(editingData.stateFlags, STATE_FLAG_RECALCULATE_VOX_MASK)) {
            barrier();
            switch(editingData.selectionType) {
                case SELECTION_TYPE_FACE:
                    createFaceMask(voxCoord);
                    break;
                case SELECTION_TYPE_BOX:
                    break;
                case SELECTION_TYPE_BRUSH:
                    break;
            }
        }
        barrier();
        switch(editingData.selectionType) {
            case SELECTION_TYPE_FACE:
                createFaceEditingMarks(voxCoord);
                break;
            case SELECTION_TYPE_BOX:
                createBoxEditingMarks(voxCoord);
                break;
            case SELECTION_TYPE_BRUSH:
                createBrushEditingMarks(voxCoord);
                break;
        }
    }

    uint oldVal = read3dImage(voxCoord, !gridData.renderFromA);
    uint newVal;
    if (hasFlag(imageLoad(voxMask, voxCoord).x, MARK_FOR_EDITING_BIT)) {    
        switch(editingData.tool) {
            case TOOL_ADD:
                newVal = oldVal != 0 ? oldVal : editingData.colorIndex;
                break;
            case TOOL_DELETE:
                newVal = 0;
                break;
            case TOOL_PAINT:
                newVal = oldVal == 0 ? 0 : editingData.colorIndex;
                break;
        }
        write3dImage(voxCoord, gridData.renderFromA, newVal);
    } else {
        write3dImage(voxCoord, gridData.renderFromA, oldVal);
    }
}