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

#include <grpcpp/grpcpp.h>
#include "helloworld.grpc.pb.h"
#include <grpcpp/ext/proto_server_reflection_plugin.h>

using grpc::Server;
using grpc::ServerAsyncWriter;
using grpc::ServerCompletionQueue;
using grpc::ServerBuilder;
using grpc::ServerContext;
using grpc::Status;
using helloworld::Greeter;
using helloworld::ProcessRequest;
using helloworld::FrameStatus;

grpc::ServerAsyncWriter<FrameStatus>* WRITER;
void* TAG;
std::shared_ptr<ServerCompletionQueue> COMPLETION_QUEUE;

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
    FrameStatus status;
    status.set_frame_count(frames_processed);
    for (int i = 0; i < nboxes; i++) {
        for (int j = 0; j < l.classes; j++) {
            if (dets[i].prob[j] > class_thresh) {
                auto* name = status.add_names();
                name->assign(names[j]);
                status.add_probabilities(dets[i].prob[j]);
            }
        }
    }

    printf("Writing. Tag %p\n", TAG);
    grpc::WriteOptions opts;
    opts.set_write_through();
    WRITER->Write(status, opts, TAG);
    void* tag = reinterpret_cast<void*>(0xfffffffff);
    bool ok;
    while (tag != TAG) {
        COMPLETION_QUEUE->Next(&tag, &ok);
    }
    TAG++;
    
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

class GreeterServerImpl final {
 public:
  ~GreeterServerImpl() {
    server_->Shutdown();
    cq_->Shutdown();
  }

  void Run() {
    std::string server_address = "unix:///services/detector.sock";

    ServerBuilder builder;
    builder.AddListeningPort(server_address, grpc::InsecureServerCredentials());
    builder.RegisterService(&service_);
    cq_ = builder.AddCompletionQueue();
    COMPLETION_QUEUE = cq_;
    server_ = builder.BuildAndStart();
    std::cout << "Server listening on " << server_address << std::endl;

    HandleRpcs();
  }

 private:
  class CallData {
   public:
    CallData(Greeter::AsyncService* service, ServerCompletionQueue* cq)
        : service_(service), cq_(cq), responder_(&ctx_), status_(CREATE) {
      Proceed();
    }

    void Proceed() {
      if (status_ == CREATE) {
        status_ = PROCESS;

        service_->RequestProcessVideo(&ctx_, &request_, &responder_, cq_, cq_,
                                  this);
      } else if (status_ == PROCESS) {
        new CallData(service_, cq_);

        WRITER = &responder_;
        TAG = 0;

        double time;
        const char *input_file = request_.path().c_str();
        char *name_list_file = "program_data/coco.names";
        char *cfgfile = "program_data/yolov3-tiny.cfg";
        char *weightfile = "program_data/yolov3-tiny.weights";
        
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

        // And we are done! Let the gRPC runtime know we've finished, using the
        // memory address of this instance as the uniquely identifying tag for
        // the event.
        status_ = FINISH;
        responder_.Finish(Status::OK, this);
      } else {
        GPR_ASSERT(status_ == FINISH);
        // Once in the FINISH state, deallocate ourselves (CallData).
        delete this;
      }
    }

   private:
    Greeter::AsyncService* service_;
    ServerCompletionQueue* cq_;
    ServerContext ctx_;

    ProcessRequest request_;

    ServerAsyncWriter<FrameStatus> responder_;

    enum CallStatus { CREATE, PROCESS, FINISH };
    CallStatus status_;  
  };

  // This can be run in multiple threads if needed.
  void HandleRpcs() {
    // Spawn a new CallData instance to serve new clients.
    new CallData(&service_, cq_.get());
    void* tag;  // uniquely identifies a request.
    bool ok;
    while (true) {
      // Block waiting to read the next event from the completion queue. The
      // event is uniquely identified by its tag, which in this case is the
      // memory address of a CallData instance.
      // The return value of Next should always be checked. This return value
      // tells us whether there is any kind of event or cq_ is shutting down.
      GPR_ASSERT(cq_->Next(&tag, &ok));
      GPR_ASSERT(ok);
      static_cast<CallData*>(tag)->Proceed();
    }
  }

  std::shared_ptr<ServerCompletionQueue> cq_;
  Greeter::AsyncService service_;
  std::unique_ptr<Server> server_;
};

// Logic and data behind the server's behavior.
class GreeterServiceImpl final : public Greeter::Service {
  Status ProcessVideo(ServerContext* context, const ProcessRequest* request,
                  grpc::ServerWriter<FrameStatus>* writer) override {
    return Status::OK;
  }
};
/* Run the object detection model on each decoded frame */
int main(int argc, char **argv)
{
    GreeterServerImpl server;
    server.Run();


    return 0;
}
