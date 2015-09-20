#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
}

__host__ __device__ thrust::default_random_engine random_engine(
        int iter, int index = 0, int depth = 0) {
    return thrust::default_random_engine(utilhash((index + 1) * iter) ^ utilhash(depth));
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene *hst_scene = NULL;
static glm::vec3 *dev_image = NULL;
// TODO: static variables for device memory, scene/camera info, etc
// ...

static int hst_geomCount; // number of geometries to check against
static Geom *dev_geoms; // pointer to geometries in global memory
static Material *dev_mats; // pointer to materials in global memory
static PathRay *dev_firstBounce; // cache of the first raycast of any iteration
static PathRay *dev_rayPool; // pool of rays "in flight"

void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));
    // TODO: initialize the above static variables added above
	// set up the geometries
	hst_geomCount = scene->geoms.size();
	cudaMalloc(&dev_geoms, hst_geomCount * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), sizeof(Geom) * hst_geomCount,
		cudaMemcpyHostToDevice);

	// set up the materials
	int hst_matCount = scene->materials.size();
	cudaMalloc(&dev_mats, hst_matCount * sizeof(Material));
	cudaMemcpy(dev_mats, scene->materials.data(),
		sizeof(Material) * hst_matCount, cudaMemcpyHostToDevice);

	// set up space for the first cast
	// we'll be casting a ray from every pixel
	int numPixels = scene->state.camera.resolution.x;
	numPixels *= scene->state.camera.resolution.y;
	cudaMalloc(&dev_firstBounce, numPixels * sizeof(PathRay));
	cudaMalloc(&dev_rayPool, numPixels * sizeof(PathRay));

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
    // TODO: clean up the above static variables
	cudaFree(dev_geoms);
	cudaFree(dev_mats);
	cudaFree(dev_firstBounce);
	cudaFree(dev_rayPool);

    checkCUDAError("pathtraceFree");
}

/**
 * Example function to generate static and test the CUDA-GL interop.
 * Delete this once you're done looking at it!
 */
__global__ void generateNoiseDeleteMe(Camera cam, int iter, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < cam.resolution.x && y < cam.resolution.y) {
        int index = x + (y * cam.resolution.x);

        thrust::default_random_engine rng = random_engine(iter, index, 0);
        thrust::uniform_real_distribution<float> u01(0, 1);

        // CHECKITOUT: Note that on every iteration, noise gets added onto
        // the image (not replaced). As a result, the image smooths out over
        // time, since the output image is the contents of this array divided
        // by the number of iterations.
        //
        // Your renderer will do the same thing, and, over time, it will become
        // smoother.
        image[index] += glm::vec3(u01(rng));
    }
}

__global__ void singleBounce(int iter, int geomCount) {
	// what information do we need for a single ray given index by block/grid thing?
	// we need:
	// - pointer to the sample that will have color updated OR color storage
	// - access to the "current rays" ray pool
	//		-is it better to read and write to the same place?
	//		-or have two buffers and flip them?
	//			-"next rays" memory should have same allocated size as current rays
	//			-should start off allocated full of "terminated" rays
	//			-terminated rays have ray length of much less than 1.
	//			-alternatively, terminated rays are "dark"
	// - count of ray depth
	// - so I've added a PathRay struct that contains color and depth

	// 1) grab the ray
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;

	// 2) check what it intersects with
	// 3) attenuate color appropriately
	// 4) update the ray in this slot
}

// generates the initial raycasts
__global__ void rayCast(Camera cam, PathRay* dev_rayPool) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	
	// compute x and y screen coordinates by reversing int index = x + (y * resolution.x);
	int y = index / (int)cam.resolution.x;
	int x = index - y * cam.resolution.x;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);

		// generate a PathRay to cast
		glm::vec3 ref = cam.position + cam.view;
		glm::vec3 R = glm::cross(cam.view, cam.up);
		glm::vec3 V = cam.up * glm::tan(cam.fov.y * 0.01745329251f);
		glm::vec3 H = R * glm::tan(cam.fov.x * 0.01745329251f);
		// sx = ((2.0f * x) / cam.resolution.x) - 1.0f
		// sy = ((2.0f * y) / cam.resolution.y) - 1.0f
		glm::vec3 p = H * (((2.0f * x) / cam.resolution.x) - 1.0f) +
			V * (((2.0f * y) / cam.resolution.y) - 1.0f) + ref;
		dev_rayPool[index].ray.direction = glm::normalize(p - cam.position);
		dev_rayPool[index].ray.origin = cam.position;
		dev_rayPool[index].color = glm::vec3(1.0f);
		dev_rayPool[index].depth = 0;
		dev_rayPool[index].pixelIndex = index;

		//glm::vec3 debug = glm::normalize(p - cam.position);
		//debug.x = abs(debug.x);
		//debug.y = abs(debug.y);
		//debug.z = abs(debug.z);
		//
		//image[index] += debug;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    const int blockSideLength = 8;
    const dim3 blockSize(blockSideLength, blockSideLength);
    const dim3 blocksPerGrid(
            (cam.resolution.x + blockSize.x - 1) / blockSize.x,
            (cam.resolution.y + blockSize.y - 1) / blockSize.y);

    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray is a (ray, color) pair, where color starts as the
    //     multiplicative identity, white = (1, 1, 1).
    //   * For debugging, you can output your ray directions as colors.
    // * For each depth:
    //   * Compute one new (ray, color) pair along each path (using scatterRay).
    //     Note that many rays will terminate by hitting a light or hitting
    //     nothing at all. You'll have to decide how to represent your path rays
    //     and how you'll mark terminated rays.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //       surface.
    //     * You can debug your ray-scene intersections by displaying various
    //       values as colors, e.g., the first surface normal, the first bounced
    //       ray direction, the first unlit material color, etc.
    //   * Add all of the terminated rays' results into the appropriate pixels.
    //   * Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    // * Finally, handle all of the paths that still haven't terminated.
    //   (Easy way is to make them black or background-colored.)

    // TODO: perform one iteration of path tracing

    //generateNoiseDeleteMe<<<blocksPerGrid, blockSize>>>(cam, iter, dev_image);
	dim3 iterBlockSize(blockSideLength * blockSideLength);
	dim3 iterBlocksPerGrid(
		(cam.resolution.x * cam.resolution.y + blockSize.x - 1) / blockSize.x);

	rayCast << <iterBlocksPerGrid, iterBlockSize >> >(cam, dev_rayPool);

    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid, blockSize>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
}
