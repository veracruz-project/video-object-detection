# Video object detection example

This example combines and integrates two simpler examples, the video decoder and the [deep learning server](https://github.com/veracruz-project/veracruz-examples/tree/main/deep-learning-server).
The video decoder uses [`openh264`](https://github.com/veracruz-project/openh264) to decode an H264 video into individual frames, which are converted to RGB and made palatable to an object detector built on top of the [Darknet neural network framework](https://github.com/veracruz-project/darknet). The output is a list of detected objects, associated with their detection probability, and an optional prediction image showing each detected object in a bounding box.

## Build
* Install [`wasi sdk 14`](https://github.com/WebAssembly/wasi-sdk) and set `WASI_SDK_ROOT` to point to its installation directory
* Install `imagemagick`
* Install `nasm`
* Clone the repo and update the submodules:
  ```
  git submodule update --init
  ```
* Run `make` to build [`openh264`](https://github.com/veracruz-project/openh264), [`openh264-dec`](https://github.com/veracruz-project/openh264-dec), [`darknet`](https://github.com/veracruz-project/darknet) and the main program
* Fetch the YOLO pre-trained models and generate the alphabet:
  ```
  make yolo_detection
  ```

## Prepare the input video
* Cut the MP4 video to a specific amount of frames (optional):
  ```
  ffmpeg -i in.mp4 -vf trim=start_frame=0:end_frame=<END_FRAME> -an in_cut.mp4
  ```
* Generate the input H.264 video from the MP4 video:
  ```
  ffmpeg -i in.mp4 -map 0:0 -vcodec copy -an -f h264 in.h264
  ```

## Execution outside Veracruz
* The program is expecting the following file tree that must be mirrored on the executing machine:
  ```
  + output/
  + program_data/
  +-- coco.names
  +-- labels/ (optional)
  +---- *.png
  +-- yolov3.cfg
  +-- yolov3.weights
  + video_input/
  +-- in.h264
  ```
* There are several ways to run the program outside Veracruz. In any case the prediction images can be found under `./output/`

### As a native binary
* Build as a native binary:
   ```
   make -f Makefile_native
   ```
* Run:
   ```
   ./detector
   ```

### In `wasmtime`
* Install [`wasmtime`](https://github.com/bytecodealliance/wasmtime)
* Run:
  ```
  wasmtime --dir=. detector.wasm
  ```

### In the [`freestanding execution engine`](https://github.com/veracruz-project/veracruz/tree/main/sdk/freestanding-execution-engine):
* Run:
  ```
  RUST_LOG=info RUST_BACKTRACE=1 freestanding-execution-engine -i video_input program program_data -o output -p program/detector.wasm -x jit -c -d -e
  ```

## End-to-end Veracruz deployment
* [Build Veracruz](https://github.com/veracruz-project/veracruz/blob/main/BUILD_INSTRUCTIONS.markdown)
* Depending on your environment, run `./deploy_vod_big_linux.sh` or `./deploy_vod_big_nitro.sh` to generate the certificates and the policy, deploy the Veracruz components and run the computation
* The prediction images can be found in the executing directory
