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
#include <cudamanager/PxCudaContext.h>
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
    PxRigidDynamic* actor = nullptr;
};

struct Joint {
    std::string id;
    std::string body0;
    std::string body1;
    PxD6Joint* joint = nullptr;
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
    if (!ground) fail("ground_create_failed");
    scene.addActor(*ground);
    PxRigidStatic* anchor = PxCreateStatic(physics, PxTransform(PxVec3(0.0f, 6.0f, 0.0f)),
                                           PxBoxGeometry(0.25f, 0.25f, 0.25f), material);
    if (!anchor) fail("anchor_create_failed");
    scene.addActor(*anchor);
    const float half = 0.5f;
    const float spacing = 1.2f;
    PxRigidActor* previous = anchor;
    for (int index = 0; index < 4; ++index) {
        const PxVec3 position(spacing * (index + 1), 6.0f, 0.0f);
        PxRigidDynamic* box = PxCreateDynamic(physics, PxTransform(position),
                                              PxBoxGeometry(half, half, half), material, 1.0f);
        if (!box) fail("body_create_failed");
        box->setSleepThreshold(0.0f);
        scene.addActor(*box);
        Body body;
        body.id = "box-" + std::to_string(index);
        body.actor = box;
        bodies.push_back(body);
        const PxTransform frame0(PxVec3(index == 0 ? 0.25f : half + 0.1f, 0.0f, 0.0f));
        const PxTransform frame1(PxVec3(-half - 0.1f, 0.0f, 0.0f));
        PxD6Joint* d6 = PxD6JointCreate(physics, previous, frame0, box, frame1);
        if (!d6) fail("joint_create_failed");
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

struct BodyState {
    PxTransform pose = PxTransform(PxIdentity);
    PxVec3 linear = PxVec3(0.0f);
    PxVec3 angular = PxVec3(0.0f);
};

// What one state read moved and what the driver said afterwards. bytes counts
// the buffers this program allocates and copies; the readback path leaves it
// unmeasured because PhysX performs its own copies inside fetchResults and
// exposes no count of them.
struct TransferReport {
    bool counted = false;
    int device_reads = 0;
    int device_to_host_copies = 0;
    size_t bytes = 0;
    unsigned int cuda_last_error = 0;
};

void read_states_readback(const std::vector<Body>& bodies, std::vector<BodyState>& states) {
    states.resize(bodies.size());
    for (size_t index = 0; index < bodies.size(); ++index) {
        states[index].pose = bodies[index].actor->getGlobalPose();
        states[index].linear = bodies[index].actor->getLinearVelocity();
        states[index].angular = bodies[index].actor->getAngularVelocity();
    }
}

// PxDirectGPUAPI writes into device buffers and reads its index list from one,
// so the indices travel host to device once and each quantity travels device to
// host once. A finish event turns each get into a dispatch rather than a
// blocking copy, and eventSynchronize is where the program waits; the boolean
// return "might not include asynchronous CUDA errors" per PxDirectGPUAPI.h, so
// getLastError is read afterwards and reported beside the result.
void read_states_direct(PxScene& scene, PxCudaContextManager& cuda,
                        const std::vector<Body>& bodies,
                        std::vector<BodyState>& states, TransferReport& report) {
    const PxU32 count = static_cast<PxU32>(bodies.size());
    states.resize(count);
    std::vector<PxRigidDynamicGPUIndex> indices(count);
    for (PxU32 index = 0; index < count; ++index) {
        indices[index] = bodies[index].actor->getGPUIndex();
    }

    PxDirectGPUAPI& direct = scene.getDirectGPUAPI();
    PxScopedCudaLock lock(cuda);
    PxCudaContext* context = cuda.getCudaContext();
    if (!context) fail("cuda_context_absent");

    const size_t index_bytes = count * sizeof(PxRigidDynamicGPUIndex);
    const size_t pose_bytes = count * sizeof(PxTransform);
    const size_t vector_bytes = count * sizeof(PxVec3);

    CUdeviceptr index_device = 0;
    CUdeviceptr pose_device = 0;
    CUdeviceptr linear_device = 0;
    CUdeviceptr angular_device = 0;
    if (context->memAlloc(&index_device, index_bytes)) fail("device_alloc_indices");
    if (context->memAlloc(&pose_device, pose_bytes)) fail("device_alloc_poses");
    if (context->memAlloc(&linear_device, vector_bytes)) fail("device_alloc_linear");
    if (context->memAlloc(&angular_device, vector_bytes)) fail("device_alloc_angular");
    if (context->memcpyHtoD(index_device, indices.data(), index_bytes)) fail("index_upload");

    // One event per read. A finish event is recorded at the end of the call it
    // is given to, so a single event shared across the three reads records
    // three times and reports only the last: waiting on it would prove the
    // first two complete only if PhysX dispatched all three on one stream,
    // which the interface does not state. Three events are waited on
    // individually and the three reads still dispatch before the first wait.
    CUevent finished[3] = {NULL, NULL, NULL};
    for (int slot = 0; slot < 3; ++slot) {
        if (context->eventCreate(&finished[slot], 0)) fail("event_create");
    }
    const PxRigidDynamicGPUIndex* index_pointer =
        reinterpret_cast<const PxRigidDynamicGPUIndex*>(index_device);
    if (!direct.getRigidDynamicData(reinterpret_cast<void*>(pose_device), index_pointer,
                                    PxRigidDynamicGPUAPIReadType::eGLOBAL_POSE, count, NULL, finished[0]))
        fail("direct_read_pose");
    if (!direct.getRigidDynamicData(reinterpret_cast<void*>(linear_device), index_pointer,
                                    PxRigidDynamicGPUAPIReadType::eLINEAR_VELOCITY, count, NULL, finished[1]))
        fail("direct_read_linear");
    if (!direct.getRigidDynamicData(reinterpret_cast<void*>(angular_device), index_pointer,
                                    PxRigidDynamicGPUAPIReadType::eANGULAR_VELOCITY, count, NULL, finished[2]))
        fail("direct_read_angular");
    for (int slot = 0; slot < 3; ++slot) {
        if (context->eventSynchronize(finished[slot])) fail("event_synchronize");
    }

    std::vector<PxTransform> poses(count);
    std::vector<PxVec3> linear(count);
    std::vector<PxVec3> angular(count);
    if (context->memcpyDtoH(poses.data(), pose_device, pose_bytes)) fail("pose_download");
    if (context->memcpyDtoH(linear.data(), linear_device, vector_bytes)) fail("linear_download");
    if (context->memcpyDtoH(angular.data(), angular_device, vector_bytes)) fail("angular_download");
    report.cuda_last_error = static_cast<unsigned int>(context->getLastError());

    for (PxU32 index = 0; index < count; ++index) {
        states[index].pose = poses[index];
        states[index].linear = linear[index];
        states[index].angular = angular[index];
    }

    for (int slot = 0; slot < 3; ++slot) context->eventDestroy(finished[slot]);
    context->memFree(angular_device);
    context->memFree(linear_device);
    context->memFree(pose_device);
    context->memFree(index_device);

    report.counted = true;
    report.device_reads = 3;
    report.device_to_host_copies = 3;
    report.bytes = index_bytes + pose_bytes + 2 * vector_bytes;
}

float max_component_difference(const PxVec3& left, const PxVec3& right) {
    return PxMax(PxMax(PxAbs(left.x - right.x), PxAbs(left.y - right.y)), PxAbs(left.z - right.z));
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 7) {
        std::fprintf(stderr, "usage: physx-rigid-runtime SCENE TIMESTEP_S STEPS GRAVITY_Y DEVICE_INDEX STATE_PATH\n");
        return 2;
    }
    const std::string scene_name = argv[1];
    const float timestep = std::strtof(argv[2], nullptr);
    const long steps = std::strtol(argv[3], nullptr, 10);
    const float gravity = std::strtof(argv[4], nullptr);
    const int device_index = std::atoi(argv[5]);
    const std::string state_path = argv[6];
    if (!(timestep > 0.0f) || steps < 1 || steps > 100000 || !(gravity >= 0.0f)) return 2;
    if (scene_name != "d6-chain-4") fail("unknown_scene");
    if (state_path != "readback" && state_path != "direct-gpu") fail("unknown_state_path");
    const bool direct_gpu = state_path == "direct-gpu";

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
    // PxSceneFlag::eENABLE_DIRECT_GPU_API forces eDISABLE_SLEEPING, so both
    // paths raise it: a solver that can retire a body on one path and not the
    // other differs in what it simulates, and the comparison is over the
    // transfer path alone. PxSceneDesc::isValid() refuses the direct-GPU flag
    // without eENABLE_GPU_DYNAMICS and PxBroadPhaseType::eGPU, and refuses it
    // beside eENABLE_CCD; the flag is not mutable and must be set here.
    scene_desc.flags |= PxSceneFlag::eDISABLE_SLEEPING;
    if (direct_gpu) scene_desc.flags |= PxSceneFlag::eENABLE_DIRECT_GPU_API;
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
    const bool direct_gpu_active = scene->getFlags().isSet(PxSceneFlag::eENABLE_DIRECT_GPU_API);
    if (direct_gpu != direct_gpu_active) fail("direct_gpu_flag_not_held");

    const auto simulate_start = std::chrono::steady_clock::now();
    for (long step = 0; step < steps; ++step) {
        scene->simulate(timestep);
        scene->fetchResults(true);
    }
    const auto simulate_end = std::chrono::steady_clock::now();
    if (error_callback.errors) fail("physx_error");

    // PxDirectGPUAPI answers only after a first simulation step has been taken,
    // because the scene sizes its GPU structures from the actors it holds; the
    // loop above has taken one, and the scene was built through the CPU API the
    // header directs setup to use.
    std::vector<BodyState> states;
    TransferReport transfers;
    const auto read_start = std::chrono::steady_clock::now();
    if (direct_gpu) {
        read_states_direct(*scene, *cuda, bodies, states, transfers);
    } else {
        read_states_readback(bodies, states);
    }
    const auto read_end = std::chrono::steady_clock::now();

    // The direct path disables the GPU-to-CPU copies behind the actor getters,
    // so PxRigidActor::getGlobalPose answers from whatever the last copy left.
    // Reading it beside the device value measures that divergence rather than
    // assuming it, which is what decides whether a CPU getter can stay a
    // verification path on this configuration.
    float position_divergence = 0.0f;
    float linear_divergence = 0.0f;
    if (direct_gpu) {
        for (size_t index = 0; index < bodies.size(); ++index) {
            position_divergence = PxMax(position_divergence,
                max_component_difference(bodies[index].actor->getGlobalPose().p, states[index].pose.p));
            linear_divergence = PxMax(linear_divergence,
                max_component_difference(bodies[index].actor->getLinearVelocity(), states[index].linear));
        }
    }

    std::string out = "{";
    out += "\"gpu\":{";
    out += "\"cuda_context_valid\":" + std::string(context_valid ? "true" : "false");
    out += ",\"gpu_dynamics_requested\":true,\"gpu_broadphase_requested\":true";
    out += ",\"gpu_dynamics_active\":" + std::string(dynamics_active && broadphase_gpu ? "true" : "false");
    out += ",\"direct_gpu_active\":" + std::string(direct_gpu_active ? "true" : "false");
    out += ",\"device_name\":\"" + device_name + "\",\"device_index\":" + std::to_string(device_index) + "}";
    out += ",\"state_path\":\"" + state_path + "\"";
    out += ",\"bodies\":[";
    for (size_t index = 0; index < bodies.size(); ++index) {
        const PxTransform pose = states[index].pose;
        const PxVec3 linear = states[index].linear;
        const PxVec3 angular = states[index].angular;
        if (index) out += ",";
        out += "{\"id\":\"" + bodies[index].id + "\"";
        out += ",\"position\":[" + number(pose.p.x) + "," + number(pose.p.y) + "," + number(pose.p.z) + "]";
        out += ",\"orientation\":[" + number(pose.q.x) + "," + number(pose.q.y) + "," + number(pose.q.z) + "," + number(pose.q.w) + "]";
        out += ",\"linear_velocity\":[" + number(linear.x) + "," + number(linear.y) + "," + number(linear.z) + "]";
        out += ",\"angular_velocity\":[" + number(angular.x) + "," + number(angular.y) + "," + number(angular.z) + "]";
        // PxRigidDynamicGPUAPIReadType carries pose, velocity and acceleration
        // and no sleep state, so the direct path has no source for this field
        // and reports it unmeasured rather than answering false from a flag.
        out += ",\"sleeping\":" + std::string(direct_gpu ? "null" : (bodies[index].actor->isSleeping() ? "true" : "false")) + "}";
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
    // A contact exists at the narrow phase, and PxSimulationStatistics names the
    // counters that measure it: nbDiscreteContactPairsTotal is the non-CCD pairs
    // reaching narrow phase and nbDiscreteContactPairsWithContacts the subset
    // generating at least one contact. nbActiveConstraints counts solver
    // constraints, which every joint contributes whether or not a body touches
    // anything, and the broad phase counts insertions and removals of bounds, so
    // neither answers how many pairs touch. Each counter is reported under the
    // stage it belongs to.
    PxSimulationStatistics statistics;
    scene->getSimulationStatistics(statistics);
    out += ",\"contacts\":{\"pairs\":" + std::to_string(statistics.nbDiscreteContactPairsTotal);
    out += ",\"touching\":" + std::to_string(statistics.nbDiscreteContactPairsWithContacts);
    out += ",\"cache_hits\":" + std::to_string(statistics.nbDiscreteContactPairsWithCacheHits) + "}";
    out += ",\"solver\":{\"active_constraints\":" + std::to_string(statistics.nbActiveConstraints) + "}";
    out += ",\"broadphase\":{\"adds\":" + std::to_string(statistics.getNbBroadPhaseAdds());
    out += ",\"removes\":" + std::to_string(statistics.getNbBroadPhaseRemoves()) + "}";
    // The readback path's copies happen inside fetchResults and PhysX exposes
    // no count of them, so that path reports its transfers unmeasured rather
    // than zero. The direct path counts the buffers this program allocates and
    // moves, and carries the driver's last error because the get functions'
    // boolean return may not include an asynchronous CUDA failure.
    out += ",\"transfers\":{\"counted\":" + std::string(transfers.counted ? "true" : "false");
    if (transfers.counted) {
        out += ",\"device_reads\":" + std::to_string(transfers.device_reads);
        out += ",\"device_to_host_copies\":" + std::to_string(transfers.device_to_host_copies);
        out += ",\"bytes\":" + std::to_string(transfers.bytes);
        out += ",\"cuda_last_error\":" + std::to_string(transfers.cuda_last_error);
    } else {
        out += ",\"device_reads\":null,\"device_to_host_copies\":null";
        out += ",\"bytes\":null,\"cuda_last_error\":null";
    }
    out += "}";
    out += ",\"cpu_accessor_divergence\":";
    if (direct_gpu) {
        out += "{\"position_max\":" + number(position_divergence);
        out += ",\"linear_velocity_max\":" + number(linear_divergence) + "}";
    } else {
        out += "null";
    }
    out += ",\"steps\":" + std::to_string(steps);
    out += ",\"timestep_s\":" + number(timestep);
    const double simulate_ms = std::chrono::duration<double, std::milli>(simulate_end - simulate_start).count();
    const double state_read_ms = std::chrono::duration<double, std::milli>(read_end - read_start).count();
    out += ",\"simulate_ms\":" + number(simulate_ms);
    out += ",\"state_read_ms\":" + number(state_read_ms);

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
