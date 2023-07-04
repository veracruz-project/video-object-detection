# Video object detection example

This example combines and integrates two simpler examples, the video decoder and the [deep learning server](https://github.com/veracruz-project/veracruz-examples/tree/main/deep-learning-server).  
The video decoder uses [`openh264`](https://github.com/veracruz-project/openh264) to decode an H264 video into individual frames, which are converted to RGB and made palatable to an object detector built on top of the [Darknet neural network framework](https://github.com/veracruz-project/darknet). The output is a list of detected objects, associated with their detection probability, and an optional prediction image showing each detected object in a bounding box.

## Build and setup
* Install [`wasi sdk 14`](https://github.com/WebAssembly/wasi-sdk) and set `WASI_SDK_ROOT` to point to its installation directory:
  ``` bash vod-ci-build veracruz-ci-build
  $ export WASI_VERSION=14 && \
  export WASI_VERSION_FULL=${WASI_VERSION}.0 && \
  wget https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_VERSION}/wasi-sdk-${WASI_VERSION_FULL}-linux.tar.gz && \
  tar xvf wasi-sdk-${WASI_VERSION_FULL}-linux.tar.gz && \
  echo "export WASI_SDK_ROOT=\"${PWD}/wasi-sdk-${WASI_VERSION_FULL}\"" >> ~/.bashrc && \
  . ~/.bashrc
  ```
* Install `nasm` (Ubuntu):
  ``` bash vod-ci-build veracruz-ci-build
  $ apt-get update && apt-get install -y nasm
  ```
* Clone the repo and update the submodules:
  ``` bash
  $ git clone https://github.com/veracruz-project/video-object-detection -b main && \
  cd video-object-detection && \
  git submodule update --init
  ```
* Build [`openh264`](https://github.com/veracruz-project/openh264), [`openh264-dec`](https://github.com/veracruz-project/openh264-dec), [`darknet`](https://github.com/veracruz-project/darknet) and the main program (VOD) to WebAssembly:
  ``` bash vod-ci-build veracruz-ci-build
  $ make
  ```
* Build VOD as a native binary (optional):
  ``` bash vod-ci-build veracruz-ci-build
  $ make -f Makefile_native
  ```
* Download the YOLO models and configuration files and the COCO object list:
  ``` bash vod-ci-build veracruz-ci-build
  $ mkdir -p program_data && \
  wget -P program_data \
  https://github.com/veracruz-project/video-object-detection/releases/download/20230406/yolov3.weights \
  https://github.com/veracruz-project/video-object-detection/releases/download/20230406/yolov3-tiny.weights \
  https://github.com/veracruz-project/video-object-detection/releases/download/20230406/yolov3.cfg \
  https://github.com/veracruz-project/video-object-detection/releases/download/20230406/yolov3-tiny.cfg \
  https://github.com/veracruz-project/video-object-detection/releases/download/20230406/coco.names
  ```
* Generate the alphabet (optional). Requires `imagemagick`:
  ``` bash
  $ apt-get update && apt-get install -y imagemagick && \
  make generate_alphabet
  ```

## Prepare the input video (optional)
* Cut the MP4 video to a specific amount of frames (optional):
  ``` bash
  $ ffmpeg -i in.mp4 -vf trim=start_frame=0:end_frame=<END_FRAME> -an in_cut.mp4
  ```
* Generate the input H.264 video from the MP4 video:
  ``` bash
  $ ffmpeg -i in.mp4 -map 0:0 -vcodec copy -an -f h264 in.h264
  ```
* Note that an example H264 video is available in the release assets:
  ``` bash vod-ci-video veracruz-ci-video
  $ mkdir -p video_input && \
  wget -P video_input https://github.com/veracruz-project/video-object-detection/releases/download/20230406/in.h264
  ```

## File tree
* The program is expecting the following file tree:
  ```
  + output/           (prediction images outputted by the program)
  + program_data/     (data read by the program)
  +-- coco.names      (list of detectable objects)
  +-- labels/         (alphabet (optional))
  +---- *.png
  +-- yolov3.cfg      (configuration)
  +-- yolov3.weights  (model)
  + video_input/
  +-- in.h264         (H264 video)
  ```

## Execution outside Veracruz
Running the program outside Veracruz is useful to validate the program without considering the policy and the TEE backend it runs on.  
There are several ways to do that. In any case the [file tree](#file-tree) must be mirrored on the executing machine.  
Trick: To run VOD faster, replace the big YOLO model (`yolov3.*`) with the tiny one (`yolov3-tiny.*`).

### As a standalone native binary
* Build as a native binary (cf. build steps above)
* Run:
  ``` bash vod-ci-run-native veracruz-ci-run-native
  $ mkdir -p output && \
  ./detector
  ```

### As a WebAssembly binary in `wasmtime`
* Install [`wasmtime`](https://github.com/bytecodealliance/wasmtime)
* Run:
  ``` bash vod-ci-run-wasmtime veracruz-ci-run-wasmtime
  $ mkdir -p output && \
  wasmtime --dir=. detector.wasm
  ```

### As a WebAssembly binary in the [`freestanding execution engine`](https://github.com/veracruz-project/veracruz/tree/main/sdk/freestanding-execution-engine)
* [Build the freestanding execution engine](https://github.com/veracruz-project/veracruz/tree/main/sdk/freestanding-execution-engine)
* Run:
  ``` bash veracruz-ci-run-fee
  $ mkdir -p program && \
  cp detector.wasm program && \
  mkdir -p output && \
  RUST_LOG=info RUST_BACKTRACE=1 freestanding-execution-engine -i video_input program program_data -o output -r program/detector.wasm -x jit -c -d -e
  ```

## End-to-end Veracruz deployment
An application (program, data and policy) can't be validated until the program and data are provisioned by a Veracruz client to the Runtime Manager, the policy gets verified and the program successfully executes within the enclave.  
The crux of an end-to-end deployment is to get the policy file right. To that end, a collection of deployment scripts are provided and take care of generating the certificates and the policy based on the program's [file tree](#file-tree).
* [Build Veracruz](https://github.com/veracruz-project/veracruz/blob/main/BUILD_INSTRUCTIONS.markdown)
* Depending on your environment and how you want to run VOD (WebAssembly program or provisioned native module), run the appropriate deployment script (`./deploy_*.sh`) inside a Docker container (the same as the one used to build Veracruz). This will generate the policy, deploy the Veracruz components and run the computation. Note that you must separately build the native module sandboxer prior to running dynamic or provisioned native modules. Also note that provisioned native modules are not supported on Nitro yet, so just ignore `deploy_nitro_pnm.sh` for now
* The prediction images can be found in the executing directory
