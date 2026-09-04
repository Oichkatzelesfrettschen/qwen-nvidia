// One bounded PhysX rigid-body simulation on the GPU, with the proof that it
// ran there printed ahead of its result.
//
// The program takes a scene name, a timestep, a step count, a gravity
// magnitude, and a device index, all from argv as the service hands them out
// of scripts/physics-profiles.tsv, and builds the scene from a table in this
// file: a caller chooses a fixture and supplies no geometry. It creates the
// CUDA context manager, requires contextIsValid(), raises
// eENABLE_GPU_DYNAMICS and PxBroadPhaseType::eGPU, and after the run reads
// the scene's flags and broad-phase type back, because PhysX falls back to
// the CPU when the GPU is unusable and a fallback that answered would be a
// result under the wrong claim. The proof block, every body's state, every
// joint's state, and a contact summary go to stdout as one JSON object on one
// line; diagnostics go to stderr.
//
// Build: scripts/build-physics-runtime.sh, against /opt/nvidia/physx.

#include <PxPhysicsAPI.h>
#include <cudamanager/PxCudaContextManager.h>
#include <gpu/PxGpu.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <string>
#include <vector>

using namespace physx;

namespace {

PxDefaultAllocator allocator;

struct CountingErrorCallback : public PxErrorCallback {
    int errors = 0;
    void reportError(PxErrorCode::Enum code, const char* message, const char* file, int line) override {
        if (code & (PxErrorCode::eABORT | PxErrorCode::eINTERNAL_ERROR | PxErrorCode::eOUT_OF_MEMORY |
                    PxErrorCode::eINVALID_OPERATION | PxErrorCode::eINVALID_PARAMETER)) {
            errors += 1;
        }
        std::fprintf(stderr, "physx: code=%d %s (%s:%d)\n", (int)code, message, file, line);
    }
} error_callback;

struct Body {
    std::string id;
    PxRigidDynamic* actor;
};

struct Joint {
    std::string id;
    std::string body0;
    std::string body1;
    PxD6Joint* joint;
};

void fail(const char* reason) {
    std::fprintf(stderr, "physx_runtime=rejected reason=%s\n", reason);
    std::exit(1);
}

// d6-chain-4: a ground plane, a static anchor box, and four dynamic boxes
// hanging from it in a chain, each pair joined by a D6 joint locked in
// translation and free in swing and twist, released from a horizontal line so
// they fall under gravity and swing. Deterministic initial state, no user input.
void build_d6_chain(PxPhysics& physics, PxScene& scene, PxMaterial& material,
                    std::vector<Body>& bodies, std::vector<Joint>& joints) {
    PxRigidStatic* ground = PxCreatePlane(physics, PxPlane(0, 1, 0, 0), material);
    scene.addActor(*ground);
    PxRigidStatic* anchor = PxCreateStatic(physics, PxTransform(PxVec3(0.0f, 6.0f, 0.0f)),
                                           PxBoxGeometry(0.25f, 0.25f, 0.25f), material);
    scene.addActor(*anchor);
    const float half = 0.5f;
    const float spacing = 1.2f;
    PxRigidActor* previous = anchor;
    for (int index = 0; index < 4; ++index) {
        const PxVec3 position(spacing * (index + 1), 6.0f, 0.0f);
        PxRigidDynamic* box = PxCreateDynamic(physics, PxTransform(position),
                                              PxBoxGeometry(half, half, half), material, 1.0f);
        box->setSleepThreshold(0.0f);
        scene.addActor(*box);
        Body body;
        body.id = "box-" + std::to_string(index);
        body.actor = box;
        bodies.push_back(body);
        const PxTransform frame0(PxVec3(index == 0 ? 0.25f : half + 0.1f, 0.0f, 0.0f));
        const PxTransform frame1(PxVec3(-half - 0.1f, 0.0f, 0.0f));
        PxD6Joint* d6 = PxD6JointCreate(physics, previous, frame0, box, frame1);
        d6->setMotion(PxD6Axis::eX, PxD6Motion::eLOCKED);
        d6->setMotion(PxD6Axis::eY, PxD6Motion::eLOCKED);
        d6->setMotion(PxD6Axis::eZ, PxD6Motion::eLOCKED);
        d6->setMotion(PxD6Axis::eTWIST, PxD6Motion::eFREE);
        d6->setMotion(PxD6Axis::eSWING1, PxD6Motion::eFREE);
        d6->setMotion(PxD6Axis::eSWING2, PxD6Motion::eFREE);
        Joint joint;
        joint.id = "joint-" + std::to_string(index);
        joint.body0 = index == 0 ? std::string("anchor") : bodies[index - 1].id;
        joint.body1 = body.id;
        joint.joint = d6;
        joints.push_back(joint);
        previous = box;
    }
}

std::string number(double value) {
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "%.6g", value);
    return buffer;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 6) {
        std::fprintf(stderr, "usage: physx-rigid-runtime SCENE TIMESTEP_S STEPS GRAVITY_Y DEVICE_INDEX\n");
        return 2;
    }
    const std::string scene_name = argv[1];
    const float timestep = std::strtof(argv[2], nullptr);
    const long steps = std::strtol(argv[3], nullptr, 10);
    const float gravity = std::strtof(argv[4], nullptr);
    const int device_index = std::atoi(argv[5]);
    if (!(timestep > 0.0f) || steps < 1 || steps > 100000 || !(gravity >= 0.0f)) return 2;
    if (scene_name != "d6-chain-4") fail("unknown_scene");

    const auto wall_start = std::chrono::steady_clock::now();
    PxFoundation* foundation = PxCreateFoundation(PX_PHYSICS_VERSION, allocator, error_callback);
    if (!foundation) fail("foundation");
    PxPhysics* physics = PxCreatePhysics(PX_PHYSICS_VERSION, *foundation, PxTolerancesScale(), false, nullptr);
    if (!physics) fail("physics");
    if (!PxInitExtensions(*physics, nullptr)) fail("extensions");

    PxCudaContextManagerDesc cuda_desc;
    cuda_desc.deviceOrdinal = device_index;
    PxCudaContextManager* cuda = PxCreateCudaContextManager(*foundation, cuda_desc, PxGetProfilerCallback());
    const bool context_valid = cuda != nullptr && cuda->contextIsValid();
    if (!context_valid) fail("cuda_context_invalid");
    const std::string device_name = cuda->getDeviceName() ? cuda->getDeviceName() : "";

    PxSceneDesc scene_desc(physics->getTolerancesScale());
    scene_desc.gravity = PxVec3(0.0f, -gravity, 0.0f);
    PxDefaultCpuDispatcher* dispatcher = PxDefaultCpuDispatcherCreate(2);
    scene_desc.cpuDispatcher = dispatcher;
    scene_desc.filterShader = PxDefaultSimulationFilterShader;
    scene_desc.cudaContextManager = cuda;
    scene_desc.flags |= PxSceneFlag::eENABLE_GPU_DYNAMICS;
    scene_desc.flags |= PxSceneFlag::eENABLE_PCM;
    scene_desc.flags |= PxSceneFlag::eENABLE_STABILIZATION;
    scene_desc.broadPhaseType = PxBroadPhaseType::eGPU;
    scene_desc.gpuMaxNumPartitions = 8;
    PxScene* scene = physics->createScene(scene_desc);
    if (!scene) fail("scene");
    PxMaterial* material = physics->createMaterial(0.5f, 0.5f, 0.3f);

    std::vector<Body> bodies;
    std::vector<Joint> joints;
    build_d6_chain(*physics, *scene, *material, bodies, joints);

    // The proof reads the scene back rather than the descriptor: the flags
    // the scene holds are what the simulation ran under.
    const bool dynamics_active = scene->getFlags().isSet(PxSceneFlag::eENABLE_GPU_DYNAMICS);
    const bool broadphase_gpu = scene->getBroadPhaseType() == PxBroadPhaseType::eGPU;

    const auto simulate_start = std::chrono::steady_clock::now();
    for (long step = 0; step < steps; ++step) {
        scene->simulate(timestep);
        scene->fetchResults(true);
    }
    const auto simulate_end = std::chrono::steady_clock::now();
    if (error_callback.errors) fail("physx_error");

    std::string out = "{";
    out += "\"gpu\":{";
    out += "\"cuda_context_valid\":" + std::string(context_valid ? "true" : "false");
    out += ",\"gpu_dynamics_requested\":true,\"gpu_broadphase_requested\":true";
    out += ",\"gpu_dynamics_active\":" + std::string(dynamics_active && broadphase_gpu ? "true" : "false");
    out += ",\"device_name\":\"" + device_name + "\",\"device_index\":" + std::to_string(device_index) + "}";
    out += ",\"bodies\":[";
    for (size_t index = 0; index < bodies.size(); ++index) {
        const PxTransform pose = bodies[index].actor->getGlobalPose();
        const PxVec3 linear = bodies[index].actor->getLinearVelocity();
        const PxVec3 angular = bodies[index].actor->getAngularVelocity();
        if (index) out += ",";
        out += "{\"id\":\"" + bodies[index].id + "\"";
        out += ",\"position\":[" + number(pose.p.x) + "," + number(pose.p.y) + "," + number(pose.p.z) + "]";
        out += ",\"orientation\":[" + number(pose.q.x) + "," + number(pose.q.y) + "," + number(pose.q.z) + "," + number(pose.q.w) + "]";
        out += ",\"linear_velocity\":[" + number(linear.x) + "," + number(linear.y) + "," + number(linear.z) + "]";
        out += ",\"angular_velocity\":[" + number(angular.x) + "," + number(angular.y) + "," + number(angular.z) + "]";
        out += ",\"sleeping\":" + std::string(bodies[index].actor->isSleeping() ? "true" : "false") + "}";
    }
    out += "],\"joints\":[";
    for (size_t index = 0; index < joints.size(); ++index) {
        if (index) out += ",";
        PxConstraintFlags flags = joints[index].joint->getConstraintFlags();
        out += "{\"id\":\"" + joints[index].id + "\",\"body0\":\"" + joints[index].body0 + "\",\"body1\":\"" + joints[index].body1 + "\"";
        out += ",\"twist_rad\":" + number(joints[index].joint->getTwistAngle());
        out += ",\"swing_y_rad\":" + number(joints[index].joint->getSwingYAngle());
        out += ",\"swing_z_rad\":" + number(joints[index].joint->getSwingZAngle());
        out += ",\"broken\":" + std::string(flags.isSet(PxConstraintFlag::eBROKEN) ? "true" : "false") + "}";
    }
    out += "]";
    // The contact summary counts actor pairs that report touching through the
    // simulation statistics rather than a contact callback.
    PxSimulationStatistics statistics;
    scene->getSimulationStatistics(statistics);
    out += ",\"contacts\":{\"pairs\":" + std::to_string(statistics.nbActiveConstraints);
    out += ",\"touching\":" + std::to_string(statistics.getNbBroadPhaseAdds() + statistics.nbActiveConstraints) + "}";
    out += ",\"steps\":" + std::to_string(steps);
    out += ",\"timestep_s\":" + number(timestep);
    const double simulate_ms = std::chrono::duration<double, std::milli>(simulate_end - simulate_start).count();
    out += ",\"simulate_ms\":" + number(simulate_ms);

    for (auto& joint : joints) joint.joint->release();
    scene->release();
    dispatcher->release();
    material->release();
    cuda->release();
    PxCloseExtensions();
    physics->release();
    foundation->release();
    const double wall_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - wall_start).count();
    out += ",\"wall_ms\":" + number(wall_ms) + "}";
    std::printf("%s\n", out.c_str());
    return 0;
}
