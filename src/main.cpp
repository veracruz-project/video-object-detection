/*
This file contains the main functions for performing object detection.
First, the object detection model is loaded, then the video decoder executes
until every frame in the video is decoded.
A callback is configured to be called whenever a frame is available, whereupon
it is fed to the object detection model which outputs a prediction.

AUTHORS

The Veracruz Development Team.

COPYRIGHT AND LICENSING

See the `LICENSE_MIT.markdown` file in the example's root directory for
copyright and licensing information.
Based on darknet, YOLO LICENSE https://github.com/pjreddie/darknet/blob/master/LICENSE
*/

extern "C"
{
    #include "darknet.h"
}
#include "codec_def.h"
#include "h264dec.h"
#include "utils.h"

#include <string.h>


/* Keep track of the number of frames processed */
int frames_processed = 0;

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
 *   - objectness threshold above which an object is considered detected
 *   - class threshold above which a class is considered detected assuming
 *     objectness within the detection box
 *   - hierarchical threshold (only used by YOLO9000)
 *   - output (prediction) file path: doesn't include the file extension
 *   - whether detection boxes should be drawn and saved to a file
 * Output: None
 */
void run_darknet_detector(image im, image im_sized, float objectness_thresh,
                          float class_thresh, float hier_thresh, char *outfile,
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
    detection *dets = get_network_boxes(net, im.w, im.h, objectness_thresh,
                                        hier_thresh, 0, 1, &nboxes);
    if (nms)
        do_nms_sort(dets, nboxes, l.classes, nms);
    printf("Detection probabilities:\n");

    // Draw boxes around detected objects
    if (draw_detection_boxes) {
        draw_detections(im, dets, nboxes, objectness_thresh, names, alphabet,
                        l.classes);

        // Output the prediction
        if (outfile) {
            printf("Saving prediction to %s.jpg...\n", outfile);
            time  = what_time_is_it_now();
            save_image(im, outfile);
            printf("Write duration: %lf seconds\n",
                    what_time_is_it_now() - time);
        }
    } else {
        // Print classes above a certain detection threshold
        print_detection_probabilities(im, dets, nboxes, class_thresh, names,
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

    // Resize image to fit the darknet model
    im_sized = letterbox_image(im, net->w, net->h);

    printf("Image normalized and resized: %lf seconds\n",
                what_time_is_it_now() - time);

    time = what_time_is_it_now();

    strcat(outfile, outfile_prefix);
    sprintf(frame_number_suffix, ".%d", frames_processed);
    strcat(outfile, frame_number_suffix);

    run_darknet_detector(im, im_sized, .1, .1, .5, outfile, true);
    printf("Detector run: %lf seconds\n", what_time_is_it_now() - time);
    frames_processed++;
}

/* Run the object detection model on each decoded frame */
int main(int argc, char **argv)
{
    double time;
    char *input_file = "video_input/in.h264";
    char *name_list_file = "program_data/coco.names";
    char *cfgfile = "program_data/yolov3.cfg";
    char *weightfile = "program_data/yolov3.weights";
    // XXX: Box annotation is temporarily disabled until we find a way to
    // efficiently provision a batch of files to the enclave (file archive?)
    bool annotate_boxes = false;

    printf("Initializing detector...\n");
    time  = what_time_is_it_now();
    init_darknet_detector(name_list_file, cfgfile, weightfile, annotate_boxes);
    printf("Arguments loaded and network parsed: %lf seconds\n",
                what_time_is_it_now() - time);

    printf("Starting decoding...\n");
    time  = what_time_is_it_now();
    int x = h264_decode(input_file, "", false, &on_frame_ready);
    printf("Finished decoding: %lf seconds\n",
                what_time_is_it_now() - time);
    if (frames_processed == 0)
        printf("No frames were processed. The input video was whether empty or not an H.264 video\n");


    return x;
}
