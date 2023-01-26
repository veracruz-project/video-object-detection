/*
This file contains the main functions for performing object detection.
First, the input video is decrypted by the AES native module, then the object
detection model is loaded, then the video decoder executes until every frame in
the video is decoded.
A callback is configured to be called whenever a frame is available, whereupon
it is fed to the object detection model which outputs a prediction and
optionally saves it to disk.

AUTHORS

The Veracruz Development Team.

COPYRIGHT AND LICENSING

See the `LICENSE_MIT.markdown` file in the example's root directory for
copyright and licensing information.
Based on Darknet, YOLO LICENSE https://github.com/pjreddie/darknet/blob/master/LICENSE
*/

extern "C"
{
    #include "darknet.h"
}
#include "codec_def.h"
#include "h264dec.h"
#include "mbedtls/cipher.h"
#include "utils.h"

#include <string.h>


/* Cipher's key length in bits */
unsigned int KEY_LENGTH = 128;

/* Cipher's block size in bits */
unsigned int BLOCK_SIZE = 128;

/* Keep track of the number of frames processed */
unsigned int frames_processed = 0;

/* Network state, to be initialized by `init_darknet_detector()` */
char **names;
network *net;
image **alphabet;

/* Initialize the Darknet model (neural network)
 * Input:
 *   - name list file: contains the labels of all objects
 *   - network configuration file
 *   - weight file
 *   - whether detection boxes should be annotated with the name of the detected
 *     object (requires an alphabet)
 * Output: None
 */
void init_darknet_detector(char *name_list_file, char *cfgfile,
                           char *weightfile, bool annotate_boxes)
{
    // Get name list
    names = get_labels(name_list_file);

    // Load network
    net = load_network(cfgfile, weightfile, 0);
    set_batch_network(net, 1);

    // Load alphabet (set of images corresponding to symbols). It is used to
    // write the labels next to the detection boxes. Try to load symbols from
    // `program_data/labels/<symbol_index>_<symbol_size>.png`
    if (annotate_boxes)
        alphabet = load_alphabet_from_path("program_data/labels/%d_%d.png");
}

/* Feed an image to the object detection model.
 * Output a prediction, i.e. the same image with boxes highlighting the detected
 * objects
 * Input:
 *   - initial image to be annotated with detection boxes
 *   - image to be processed by the model
 *   - detection threshold
 *   - hierarchy threshold
 *   - output (prediction) file path: doesn't include the file extension
 *   - whether detection boxes should be drawn and saved to a file
 * Output: None
 */
void run_darknet_detector(image im, image im_sized, float thresh,
                          float hier_thresh, char *outfile,
                          bool draw_detection_boxes)
{
    double time;
    float nms = .45;

    // Run network prediction
    float *X = im_sized.data;
    printf("Starting prediction...\n");
    time  = what_time_is_it_now();
    network_predict(net, X);
    printf("Prediction duration: %lf seconds\n",
                what_time_is_it_now() - time);

    // Get detections
    int nboxes = 0;
    layer l = net->layers[net->n - 1];
    detection *dets = get_network_boxes(net, im.w, im.h, thresh, hier_thresh, 0,
                                        1, &nboxes);
    if (nms)
        do_nms_sort(dets, nboxes, l.classes, nms);
    printf("Detection probabilities:\n");

    // Draw boxes around detected objects
    if (draw_detection_boxes) {
        draw_detections(im, dets, nboxes, thresh, names, alphabet, l.classes);

        // Output the prediction
        if (outfile) {
            printf("Saving prediction to %s.jpg...\n", outfile);
            time  = what_time_is_it_now();
            save_image(im, outfile);
            printf("Write duration: %lf seconds\n",
                        what_time_is_it_now() - time);
        }
    } else {
        print_detection_probabilities(im, dets, nboxes, thresh, names,
                                      l.classes);
    }
    free_detections(dets, nboxes);

    free_image(im);
    free_image(im_sized);
}

/* Callback called by the H.264 decoder whenever a frame is decoded and ready
 * Input: OpenH264's I420 frame buffer
 * Output: None
 */
void on_frame_ready(SBufferInfo *bufInfo)
{
    image im, im_sized;
    double time;
    const char *outfile_prefix = "output/prediction";
    char outfile[strlen(outfile_prefix) + 12];
    outfile[0] = '\0';
    char frame_number_suffix[12];

    printf("Image %d ===========================\n", frames_processed);

    time = what_time_is_it_now();

    im = load_image_from_raw_yuv(bufInfo);

    // Resize image to fit the Darknet model
    im_sized = letterbox_image(im, net->w, net->h);

    printf("Image normalized and resized: %lf seconds\n",
                what_time_is_it_now() - time);

    time = what_time_is_it_now();

    strcat(outfile, outfile_prefix);
    sprintf(frame_number_suffix, ".%d", frames_processed);
    strcat(outfile, frame_number_suffix);

    run_darknet_detector(im, im_sized, .1, .5, outfile, true);
    printf("Detector run: %lf seconds\n", what_time_is_it_now() - time);
    frames_processed++;
}

int decrypt_video(char *encrypted_video_path, char *decrypted_video_path, char *key_path, char *iv_path)
{
    FILE *f;
    size_t n;
    long input_file_size;
    unsigned char key[KEY_LENGTH / 8];
    unsigned char iv[BLOCK_SIZE / 8];
    unsigned char *input_buffer = NULL, *output_buffer = NULL;
    size_t output_len;
    mbedtls_cipher_context_t ctx;
    mbedtls_cipher_type_t type;
    int ret = 1, mbedtls_ret = 1;

    // Read key
    f = fopen(key_path, "r");
    if (f == NULL) {
        printf("Couldn't open %s\n", key_path);
        goto exit;
    }
    n = fread(key, sizeof(key), 1, f);
    fclose(f);
    if (n != 1) {
        printf("Invalid key length. Should be %d bits long\n", KEY_LENGTH);
        goto exit;
    }

    // Read IV
    f = fopen(iv_path, "r");
    if (f == NULL) {
        printf("Couldn't open %s\n", iv_path);
        goto exit;
    }
    n = fread(iv, sizeof(iv), 1, f);
    fclose(f);
    if (n != 1) {
        printf("Invalid IV length. Should be %d bits long\n", BLOCK_SIZE);
        goto exit;
    }

    // Determine input file size
    f = fopen(encrypted_video_path, "r");
    if (f == NULL) {
        printf("Couldn't open %s\n", encrypted_video_path);
        goto exit;
    }
    fseek(f, 0L, SEEK_END);
    input_file_size = ftell(f);
    rewind(f);

    // Allocate input buffer the size of the input file
    input_buffer = (unsigned char *) malloc(input_file_size);
    if (!input_buffer) {
        printf("Couldn't allocate input buffer\n");
        goto free_buffers;
    }

    // Allocate output buffer the size of the input buffer (can't be longer than
    // that due to padding)
    output_buffer = (unsigned char *) malloc(input_file_size);
    if (!output_buffer) {
        printf("Couldn't allocate output buffer\n");
        goto free_buffers;
    }

    // Read input file
    n = fread(input_buffer, input_file_size, 1, f);
    fclose(f);
    if (n != 1) {
        printf("Failure reading %s\n", encrypted_video_path);
        goto free_buffers;
    }

    // Initialize decryption context
    type = MBEDTLS_CIPHER_AES_128_CTR;
    mbedtls_cipher_init(&ctx);
    if ((mbedtls_ret = mbedtls_cipher_setup(&ctx, mbedtls_cipher_info_from_type(type))) != 0) {
        printf("mbedtls_cipher_setup failed: %d\n", mbedtls_ret);
        goto mbedtls_exit;
    }
    if ((mbedtls_ret = mbedtls_cipher_setkey(&ctx, key, KEY_LENGTH, MBEDTLS_DECRYPT)) != 0) {
        printf("mbedtls_cipher_setkey failed: %d\n", mbedtls_ret);
        goto mbedtls_exit;
    }

    // Decrypt buffer
    if ((mbedtls_ret = mbedtls_cipher_crypt(&ctx, iv, BLOCK_SIZE / 8, input_buffer, input_file_size, output_buffer, &output_len)) != 0) {
        printf("mbedtls_cipher_crypt failed: %d\n", mbedtls_ret);
        goto mbedtls_exit;
    }

    // Write result to `decrypted_video_path`
    f = fopen(decrypted_video_path, "w");
    if (f == NULL) {
        printf("Couldn't open %s\n", decrypted_video_path);
        goto mbedtls_exit;
    }
    n = fwrite(output_buffer, output_len, 1, f);
    fclose(f);
    if (n != 1) {
        printf("Failure writing %s\n", decrypted_video_path);
        goto mbedtls_exit;
    }

    ret = 0;

mbedtls_exit:
    mbedtls_cipher_free(&ctx);
    mbedtls_platform_zeroize(input_buffer, input_file_size);
    mbedtls_platform_zeroize(output_buffer, input_file_size);
    mbedtls_platform_zeroize(key, sizeof(key));
    mbedtls_platform_zeroize(iv, sizeof(iv));

free_buffers:
    free(input_buffer);
    free(output_buffer);

exit:
    return ret;
}

/* Run the object detection model on each decoded frame */
int main(int argc, char **argv)
{
    double time;
    char *encrypted_video_path = "s3_app_input/in_enc.h264";
    char *decrypted_video_path = "program_internal/in.h264";
    char *key_path = "user_input/key";
    char *iv_path = "user_input/iv";
    char *name_list_file = "program_data/coco.names";
    char *cfgfile = "program_data/yolov3.cfg";
    char *weightfile = "program_data/yolov3.weights";
    // XXX: Box annotation is temporarily disabled until we find a way to
    // efficiently provision a batch of files to the enclave (file archive?)
    bool annotate_boxes = false;

    // Decrypt input video
    printf("Decrypting video...\n");
    if (decrypt_video(encrypted_video_path, decrypted_video_path, key_path, iv_path) != 0) {
        printf("Couldn't decrypt %s\n", encrypted_video_path);
        return 1;
    }

    // Initialize Darknet
    printf("Initializing detector...\n");
    time  = what_time_is_it_now();
    init_darknet_detector(name_list_file, cfgfile, weightfile, annotate_boxes);
    printf("Arguments loaded and network parsed: %lf seconds\n",
                what_time_is_it_now() - time);

    // Decode video and run object detection on each frame
    printf("Starting decoding...\n");
    time  = what_time_is_it_now();
    int x = h264_decode(decrypted_video_path, "", false, &on_frame_ready);
    printf("Finished decoding: %lf seconds\n",
           what_time_is_it_now() - time);
    if (frames_processed == 0)
        printf("No frames were processed. The input video was whether empty or not an H.264 video\n");

    return x;
}
