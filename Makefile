# Makefile for the deep learning server example
#
# AUTHORS
#
# The Veracruz Development Team.
#
# COPYRIGHT AND LICENSING
#
# See the `LICENSE_MIT.markdown` file in the Veracruz deep learning server 
# example repository root directory for copyright and licensing information.


##########################################################
EXEC=detector.wasm
DARKNET_PATH = darknet
OPENH264_LIB_PATH = openh264
OPENH264DEC_LIB_PATH = openh264-dec
MBEDCRYPTO_LIB_PATH = mbedtls/library
MBEDTLS_INCLUDE_PATH = mbedtls/include
VPATH=./$(DARKNET_PATH)
OBJ=wasm

############
ifeq ($(shell uname), Darwin)
	OS=macos
endif
ifeq ($(shell uname), Linux)
	OS=linux
endif

############
# wasi sdk toolchain
WASI_SDK_SYSROOT=$(WASI_SDK_ROOT)/share/wasi-sysroot
CLANG_FLAGS=--target=wasm32-wasi
CC=$(WASI_SDK_ROOT)/bin/clang --sysroot=$(WASI_SDK_SYSROOT) $(CLANG_FLAGS)
CXX=$(WASI_SDK_ROOT)/bin/clang++ --sysroot=$(WASI_SDK_SYSROOT) $(CLANG_FLAGS)

CFLAGS=-Wall -Wno-unused-result -Wno-unknown-pragmas -Wfatal-errors -Wno-writable-strings -fPIC -msimd128
OPTS=-Ofast
#OPTS=-O0 -g

CFLAGS+=$(OPTS)

LDFLAGS= -lm

############
# compare.c is excluded from the source because it fails to compile
DARKNET_SRC = gemm.c utils.c cuda.c deconvolutional_layer.c convolutional_layer.c list.c image.c activations.c im2col.c col2im.c blas.c crop_layer.c dropout_layer.c maxpool_layer.c softmax_layer.c data.c matrix.c network.c connected_layer.c cost_layer.c parser.c option_list.c detection_layer.c route_layer.c upsample_layer.c box.c normalization_layer.c avgpool_layer.c layer.c local_layer.c shortcut_layer.c logistic_layer.c activation_layer.c rnn_layer.c gru_layer.c crnn_layer.c demo.c batchnorm_layer.c region_layer.c reorg_layer.c tree.c  lstm_layer.c l2norm_layer.c yolo_layer.c iseg_layer.c
DARKNET_SRCS = $(addprefix $(DARKNET_PATH)/, $(DARKNET_SRC))
DARKNET_OBJS = $(DARKNET_SRCS:%.c=%.$(OBJ))

MAIN_SRCS = $(wildcard src/*.cpp)

##########################################################
.PHONY: yolo_detection clean
.DEFAULT_GOAL := all

all: $(EXEC)


##########################################################
$(EXEC): $(DARKNET_OBJS) $(MAIN_SRCS) libopenh264_wasm.a libopenh264dec_wasm.a libmbedcrypto_wasm.a
	$(CXX) $(CFLAGS) $(DARKNET_OBJS) $(MAIN_SRCS) -o $@ $(LDFLAGS) -Iinclude -I$(DARKNET_PATH) -I $(OPENH264_LIB_PATH)/codec/api/svc -I $(OPENH264DEC_LIB_PATH)/inc -I $(MBEDTLS_INCLUDE_PATH) -L $(OPENH264DEC_LIB_PATH) -lopenh264dec_wasm -L $(OPENH264_LIB_PATH) -lopenh264_wasm -L $(MBEDCRYPTO_LIB_PATH) -lmbedcrypto_wasm

$(DARKNET_PATH)/%.$(OBJ): %.c
	$(CC) $(CFLAGS) -I$(DARKNET_PATH) -Iinclude -c $< -o $@

libopenh264_wasm.a:
	make -C $(OPENH264_LIB_PATH) libopenh264_wasm.a

libopenh264dec_wasm.a:
	make -C $(OPENH264DEC_LIB_PATH)

libmbedcrypto_wasm.a:
	make -C $(MBEDCRYPTO_LIB_PATH) libmbedcrypto_wasm.a


##########################################################
yolo_detection:
	python program_data/labels/make_labels.py
	if [ ! -f "program_data/yolov3-tiny.weights" ]; then \
		wget -P program_data/ https://pjreddie.com/media/files/yolov3-tiny.weights; \
	fi
	if [ ! -f "program_data/yolov3.weights" ]; then \
		wget -P program_data/ https://pjreddie.com/media/files/yolov3.weights; \
	fi


clean:
	rm -rf $(DARKNET_OBJS) $(EXEC)
