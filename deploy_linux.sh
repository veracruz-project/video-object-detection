#!/bin/bash

BACKEND="linux"
PROFILE="${PROFILE:-debug}"
VERACRUZ_PATH="${VERACRUZ_PATH:-$HOME/veracruz}"

# Binaries
POLICY_GENERATOR_PATH="${POLICY_GENERATOR_PATH:-$VERACRUZ_PATH/workspaces/host/target/$PROFILE/generate-policy}"
CLIENT_PATH="${CLIENT_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/veracruz-client}"
SERVER_PATH="${SERVER_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/veracruz-server}"
RUNTIME_MANAGER_PATH="${RUNTIME_MANAGER_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-runtime/target/$PROFILE/runtime_manager_enclave}"

# Attestation
VTS_PATH="/opt/veraison/vts"
PROVISIONING_PATH="/opt/veraison/provisioning"
PAS_PATH="/opt/veraison/proxy_attestation_server"

# Provisions
PROGRAM_DIR="${PROGRAM_DIR:-program}"
PROGRAM_DATA_DIR="${PROGRAM_DATA_DIR:-program_data}"
VIDEO_INPUT_DIR="${VIDEO_INPUT_DIR:-video_input}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"
PROGRAM_BASENAME="detector.wasm"
PROGRAM_PATH_LOCAL="${PROGRAM_PATH_LOCAL:-./$PROGRAM_BASENAME}"
PROGRAM_PATH_REMOTE="${PROGRAM_PATH_REMOTE:-/$PROGRAM_DIR/$PROGRAM_BASENAME}"
COCO_BASENAME="coco.names"
COCO_PATH_LOCAL="${COCO_PATH_LOCAL:-$PROGRAM_DATA_DIR/$COCO_BASENAME}"
COCO_PATH_REMOTE="${COCO_PATH_REMOTE:-/$PROGRAM_DATA_DIR/$COCO_BASENAME}"
YOLOV3_CFG_BASENAME="yolov3.cfg"
YOLOV3_CFG_PATH_LOCAL="${YOLOV3_CFG_PATH_LOCAL:-$PROGRAM_DATA_DIR/$YOLOV3_CFG_BASENAME}"
YOLOV3_CFG_PATH_REMOTE="${YOLOV3_CFG_PATH_REMOTE:-/$PROGRAM_DATA_DIR/$YOLOV3_CFG_BASENAME}"
YOLOV3_WEIGHTS_BASENAME="yolov3.weights"
YOLOV3_WEIGHTS_PATH_LOCAL="${YOLOV3_WEIGHTS_PATH_LOCAL:-$PROGRAM_DATA_DIR/$YOLOV3_WEIGHTS_BASENAME}"
YOLOV3_WEIGHTS_PATH_REMOTE="${YOLOV3_WEIGHTS_PATH_REMOTE:-/$PROGRAM_DATA_DIR/$YOLOV3_WEIGHTS_BASENAME}"
INPUT_VIDEO_BASENAME="in.h264"
INPUT_VIDEO_PATH_LOCAL="${INPUT_VIDEO_PATH_LOCAL:-$VIDEO_INPUT_DIR/$INPUT_VIDEO_BASENAME}"
INPUT_VIDEO_PATH_REMOTE="${INPUT_VIDEO_PATH_REMOTE:-/$VIDEO_INPUT_DIR/$INPUT_VIDEO_BASENAME}"

# PKI
CA_CERT_CONF_PATH="${CA_CERT_CONF_PATH:-$VERACRUZ_PATH/workspaces/ca-cert.conf}"
CERT_CONF_PATH="${CERT_CONF_PATH:-$VERACRUZ_PATH/workspaces/cert.conf}"
CA_CERT_PATH="CACert.pem" # This value is hardcoded in the proxy attestation server
CA_KEY_PATH="CAKey.pem" # This value is hardcoded in the proxy attestation server
PROGRAM_CLIENT_CERT_PATH="program_client_cert.pem"
PROGRAM_CLIENT_KEY_PATH="program_client_key.pem"
DATA_CLIENT_CERT_PATH="data_client_cert.pem"
DATA_CLIENT_KEY_PATH="data_client_key.pem"
VIDEO_CLIENT_CERT_PATH="video_client_cert.pem"
VIDEO_CLIENT_KEY_PATH="video_client_key.pem"
RESULT_CLIENT_CERT_PATH="result_client_cert.pem"
RESULT_CLIENT_KEY_PATH="result_client_key.pem"

POLICY_PATH="${POLICY_PATH:-policy.json}"

PROXY_CLEANUP_SCRIPT_PATH="${PROXY_CLEANUP_SCRIPT_PATH:-$VERACRUZ_PATH/proxy_cleanup.sh}"

SERVER_LOG="${SERVER_LOG:-server.log}"



echo "=============Killing components"
killall -9 proxy_attestation_server veracruz-server veracruz-client runtime_enclave_binary
$PROXY_CLEANUP_SCRIPT_PATH || true



echo "=============Generating certificates & keys if necessary"
if [ ! -f $CA_CERT_PATH ] || [ ! -f $CA_KEY_PATH ]; then
	echo "=============Generating $CA_CERT_PATH and $CA_KEY_PATH"
	openssl ecparam -name prime256v1 -noout -genkey > $CA_KEY_PATH
	openssl req -x509 \
		-key $CA_KEY_PATH \
		-out $CA_CERT_PATH \
		-config $CA_CERT_CONF_PATH
fi
for i in "$PROGRAM_CLIENT_CERT_PATH $PROGRAM_CLIENT_KEY_PATH" "$DATA_CLIENT_CERT_PATH $DATA_CLIENT_KEY_PATH" "$VIDEO_CLIENT_CERT_PATH $VIDEO_CLIENT_KEY_PATH" "$RESULT_CLIENT_CERT_PATH $RESULT_CLIENT_KEY_PATH"; do
    set -- $i
    if [ ! -f $1 ] || [ ! -f $2 ]; then
        echo "=============Generating $1 and $2"
        openssl ecparam -name prime256v1 -genkey > $2
        openssl req -x509 \
            -key $2 \
            -out $1 \
            -config $CERT_CONF_PATH
    fi
done



echo "=============Generating policy"
$POLICY_GENERATOR_PATH \
    --max-memory-mib 2000 \
    --enclave-debug-mode \
    --enable-clock \
    --proxy-attestation-server-ip 127.0.0.1:3010 \
    --proxy-attestation-server-cert $CA_CERT_PATH \
    --veracruz-server-ip 127.0.0.1:3017 \
    --certificate-expiry "$(date --rfc-2822 -d 'now + 100 days')" \
    --css-file $RUNTIME_MANAGER_PATH \
    --certificate $PROGRAM_CLIENT_CERT_PATH \
    --capability "/$PROGRAM_DIR/:w" \
    --certificate $DATA_CLIENT_CERT_PATH \
    --capability "/$PROGRAM_DATA_DIR/:w" \
    --certificate $VIDEO_CLIENT_CERT_PATH \
    --capability "/$VIDEO_INPUT_DIR/:w" \
    --certificate $RESULT_CLIENT_CERT_PATH \
    --capability "/$PROGRAM_DIR/:x,/$OUTPUT_DIR/:r,stdout:r,stderr:r" \
    --capability "/$PROGRAM_DATA_DIR/:r,/$VIDEO_INPUT_DIR/:r,/program_internal/:rw,/$OUTPUT_DIR/:w,stdout:w,stderr:w" \
    --program-binary $PROGRAM_PATH_REMOTE=$PROGRAM_PATH_LOCAL \
    --output-policy-file $POLICY_PATH



echo "=============Running proxy attestation service"
pushd "$PWD"
cd $VTS_PATH && $VTS_PATH/vts &
cd $PROVISIONING_PATH && $PROVISIONING_PATH/provisioning &
popd
$PAS_PATH -l 127.0.0.1:3010 &
sleep 5



echo "=============Provisioning attestation personalities"
curl -X POST -H 'Content-Type: application/corim-unsigned+cbor; profile=http://arm.com/psa/iot/1' --data-binary "@/opt/veraison/psa_corim.cbor" localhost:8888/endorsement-provisioning/v1/submit
curl -X POST -H 'Content-Type: application/corim-unsigned+cbor; profile=http://aws.com/nitro' --data-binary "@/opt/veraison/nitro_corim.cbor" localhost:8888/endorsement-provisioning/v1/submit



echo "=============Running veracruz server"
RUST_LOG=error $SERVER_PATH $POLICY_PATH &> $SERVER_LOG &



echo "=============Waiting for veracruz server to be ready"
while true; do
        echo -n | telnet 127.0.0.1 3017 2>/dev/null | grep "^Connected to" && break
        sleep 1
done



echo "=============Executing veracruz client"

echo "=============Provisioning program"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --program $PROGRAM_PATH_REMOTE=$PROGRAM_PATH_LOCAL \
    --identity $PROGRAM_CLIENT_CERT_PATH \
    --key $PROGRAM_CLIENT_KEY_PATH

echo "=============Provisioning data"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data $COCO_PATH_REMOTE=$COCO_PATH_LOCAL \
    --data $YOLOV3_CFG_PATH_REMOTE=$YOLOV3_CFG_PATH_LOCAL \
    --data $YOLOV3_WEIGHTS_PATH_REMOTE=$YOLOV3_WEIGHTS_PATH_LOCAL \
    --identity $DATA_CLIENT_CERT_PATH \
    --key $DATA_CLIENT_KEY_PATH

echo "=============Provisioning video"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data $INPUT_VIDEO_PATH_REMOTE=$INPUT_VIDEO_PATH_LOCAL \
    --identity $VIDEO_CLIENT_CERT_PATH \
    --key $VIDEO_CLIENT_KEY_PATH

echo "=============Requesting computation"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --compute $PROGRAM_PATH_REMOTE \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH

echo "=============Querying results (stdout and stderr)"
dump=$(RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --result stdout=- \
    --result stderr=- \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH \
    -n)
echo "$dump"
frame_count=$(echo "$dump" | grep "^Frames:" | awk '{print $2}')

echo "=============Querying results (predictions)"
for ((i=0;i<frame_count;i++)); do
       result_line="$result_line --result /$OUTPUT_DIR/prediction.$i.jpg=prediction.$i.jpg"
done
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    $result_line \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH



echo "=============Killing components"
killall -9 proxy_attestation_server veracruz-server veracruz-client runtime_enclave_binary
$PROXY_CLEANUP_SCRIPT_PATH || true
