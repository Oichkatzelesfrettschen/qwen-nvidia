#include <cstdio>

__global__ void saxpy_smoke(float *out, const float *in, float a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        out[i] = a * in[i] + out[i];
    }
}

int main() {
    const int n = 1 << 20;
    float *in = nullptr;
    float *out = nullptr;
    if (cudaMalloc(&in, n * sizeof(float)) != cudaSuccess) { return 1; }
    if (cudaMalloc(&out, n * sizeof(float)) != cudaSuccess) { return 1; }
    cudaMemset(in, 0, n * sizeof(float));
    cudaMemset(out, 0, n * sizeof(float));
    saxpy_smoke<<<(n + 255) / 256, 256>>>(out, in, 2.0f, n);
    cudaError_t status = cudaDeviceSynchronize();
    printf("smoke_kernel=%s\n", cudaGetErrorString(status));
    cudaFree(in);
    cudaFree(out);
    return status == cudaSuccess ? 0 : 1;
}
